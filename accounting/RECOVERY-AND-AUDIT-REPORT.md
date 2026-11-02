# AL GABAS PHONE ERP — Recovery & Static Audit Report
Date: 2026-11-02

Status: **static repository review only**. No Supabase production queries, SQL migrations, app deployments, or live data changes were performed.

## Repository state verified
- Repository: `ALGABAS26/al-gabas-phone`
- Production/default branch: `main`
- Review branch: `erp-security-fixes-draft`
- Compared refs: draft branch is 1 commit ahead of main and 0 behind.
- The review branch contains two documentation-only commits: `accounting/WRITE-PATH-HARDENING-DRAFT.md` and this report. No application or SQL code changes are present on that branch.
- Main branch contains `accounting/app.js`, `schema.sql`, and upgrades through `upgrade-14.sql`.

## Scope and preservation boundaries
- ERP work only.
- Do not modify `public.products`, its RLS/grants, storefront code, or product-admin flow.
- Do not run migrations or GRANT/REVOKE changes against production during this review.
- Do not enable additional shops or share the owner's account until end-to-end tenant isolation is implemented and tested.

## Recovery of the two functions supplied in the new chat
1. The supplied `erp_create_purchase` is represented in the repository's `accounting/upgrade-12.sql`. It includes the IMEI-aware purchase workflow: validates per-device IMEI units, checks Luhn, creates `erp_product_units`, and links them to purchase invoice lines through `erp_purchase_invoice_item_units`.
2. The repository's `erp_create_sale` is defined in `accounting/upgrade-04.sql`. It checks stock and available tracked units, marks selected IMEI units sold, writes invoice/payment rows, and posts cash inflows.
3. The sale/purchase return IMEI safeguards are added in `upgrade-11.sql` and `upgrade-12.sql`. The return-line triggers validate and update the exact linked IMEI units. The older inline comment in `erp_post_return` saying sale serials are not linked is stale after those later upgrades and should be corrected in a future code-only migration/documentation pass.

## Confirmed application write paths
The browser application currently uses direct table writes for these eight workflows:
1. Product creation plus optional IMEI unit creation (`erp_products`, `erp_product_units`).
2. Fawry transaction creation (`erp_fawry_transactions`).
3. Cash opening-balance upsert (`erp_cash_accounts`).
4. Manual cash movement (`erp_cash_movements`).
5. Party creation (`erp_parties`).
6. Party ledger transaction creation (`erp_party_transactions`).
7. Maintenance intake (`erp_maintenance_orders`).
8. Shop settings upsert (`erp_shop_settings`).

Existing atomic RPCs called by the app include:
- `erp_my_shop_profile`
- `erp_save_fawry_daily_close`
- `erp_init_cash_accounts`
- `erp_transfer_cash`
- `erp_create_sale`
- `erp_create_purchase`
- `erp_record_expense`
- `erp_post_stock_count`
- `erp_post_return`

Do not revoke the direct-write privileges until all eight write paths have been replaced and regression-tested.

## Static review findings to address
### A. Explicit NULL validation is incomplete
- `erp_create_sale` and `erp_create_purchase`: explicitly reject SQL NULL / JSON null item and payment payloads; explicitly validate each item's product ID, quantity, and price/cost; explicitly validate each payment's account code and amount. Current comparisons using `NOT IN`, `<`, or `<=` can evaluate to NULL rather than TRUE.
- `erp_record_expense`: `p_account_code NOT IN (...)` does not explicitly reject NULL. The table constraint may ultimately reject it, but the function should return a clear Arabic validation error.
- `erp_transfer_cash`: explicitly reject NULL source and destination account codes before the `NOT IN` checks.
- `erp_save_fawry_daily_close`: explicitly reject NULL date and numeric values. Its current non-negative checks do not reject NULL by themselves.

### B. Fawry daily close consistency
- The current close function validates the opening balance against the last earlier closing balance, but same-day concurrent writes need serialization.
- Historical edits may leave later opening balances inconsistent. Choose one explicit policy: reject edits when later closes exist, or recalculate and validate the complete subsequent chain atomically.
- Preserve idempotency for the top-up cash movement when a daily close is edited.

### C. Return traceability
- `erp_post_return` currently creates sale-refund cash movements with `source_id = gen_random_uuid()`, rather than a stable link to the return record. Change this in a reviewed migration so cash movement history can be traced back to the exact return.
- Keep the existing exact invoice-line and IMEI return guards; do not weaken or remove them.

### D. Tenant readiness
- `upgrade-13.sql` adds shop, membership, subscription, and audit metadata, while `upgrade-14.sql` adds a current-shop profile read.
- The core ERP authorization remains owner-scoped. `shop_id` is not yet enforced consistently across core tables, direct reads/writes, RPCs, exports, and foreign-key relationships.
- This remains a single-owner ERP. It is not ready for additional shops or multi-tenant onboarding.

### E. Security migration order
- Remove unnecessary `anon` access and dangerous client privileges only after the direct write paths are migrated and tested.
- Keep `authenticated` permissions required by current app writes until their RPC replacements ship.
- Treat existing object ACLs and default privileges for future objects separately.
- Audit client RPC EXECUTE privileges separately from trigger functions.
- Never change the storefront's `public.products` permissions as part of ERP hardening.

## Required next implementation sequence
1. Build a current schema/function/policy/ACL inventory from a restorable production backup or read-only inspection; do not expose secrets.
2. Prepare and test RPC replacements for the eight direct-write workflows, one workflow at a time, on a staging project.
3. Harden NULL/type/range/ownership validation in sale, purchase, expense, Fawry close, transfer, and return functions.
4. Add stable return-to-cash movement traceability.
5. Run regression tests for sale, purchase, IMEI receive/sell/return, expenses, Fawry close, cash transfer, stock count, and maintenance.
6. Only then prepare least-privilege grants and the coordinated tenant-isolation migration.
7. Require explicit owner approval before production SQL, merging to `main`, or deployment.

## Test matrix (not yet executed)
- Two authenticated test owners cannot read, update, or reference each other's ERP rows.
- Invalid/null payloads are rejected with clear errors and no partial records.
- Purchase creates the correct stock, weighted average cost, supplier ledger, cash movements, IMEI units, and purchase-unit links atomically.
- Sale reduces stock, selects only in-stock IMEI units, records split payments, and links sold units to exact invoice lines.
- Sale return restores only the original sold IMEI units; purchase return changes only the original received units.
- Cash movements cannot overdraw any account, including under concurrent operations.
- Fawry daily close edits preserve next-day opening balance consistency and one top-up movement per close.
- Existing storefront products, policies, and public website remain unchanged.

## Execution status
**No production changes have been made.** This report records static findings and the safe order of work; it is not evidence that any test has passed.


## Second-pass audit addendum (2026-11-02)

This addendum is based on reading the actual SQL definitions in `main` (upgrades 02-14) and the current browser write handlers in `accounting/app.js`. It remains static review only.

### Verified branch state correction
- Current comparison is `erp-security-fixes-draft` against `main`: **2 commits ahead, 0 behind**.
- Those two commits add this report and `WRITE-PATH-HARDENING-DRAFT.md`; no executable app or SQL files have been changed on the review branch.

### Confirmed security/integrity issue: owner-scoped RLS does not guarantee same-owner foreign-key relationships
- Several tables use a foreign key to a parent row's UUID alone, while storing a separate `owner_id`. RLS checks the child row's `owner_id=auth.uid()`, but that alone does not prove the referenced parent belongs to the same owner.
- Concrete examples include `erp_party_transactions.party_id`, `erp_sales_invoice_items.product_id`, `erp_purchase_invoice_items.product_id`, `erp_stock_count_items.count_id/product_id`, and return-related parent/product references. The invoice RPCs perform owner-scoped lookups for their normal paths, but direct authenticated table writes remain granted on many ERP tables.
- `erp_sales_invoice_item_units` has owner-scoped RLS and foreign keys, but unlike the purchase-unit mapping table it has no equivalent trigger validating that the invoice line and product unit both belong to `new.owner_id` and that their product IDs match.
- `erp_purchase_invoice_item_units` does have `erp_guard_purchase_unit_link()`, which explicitly validates line owner, unit owner, and product match. This is a useful pattern, but it does not automatically protect other tables.
- Required remediation: add composite owner-aware foreign keys where practical, or narrowly scoped BEFORE triggers for every cross-table relationship that cannot be expressed safely as a composite FK. Test direct authenticated writes as two different users. Do not assume RLS alone prevents cross-owner references.

### Confirmed IMEI sale-linking edge case to test before release
- `erp_link_sold_units_to_sale_line()` selects the oldest units for a product where `status='sold'` and no sale-line mapping exists. The trigger comment describes these as newly sold units, but the query itself does not distinguish units sold by the current invoice from older sold-but-unlinked units.
- If any tracked devices were sold before upgrade 11, a later sale can potentially attach an older unlinked serial to a new invoice line. This is a static risk requiring a targeted regression test and a safer transaction-scoped selection mechanism before relying on the mapping for returns. Do not rewrite or disable the trigger without a migration plan and tests.

### Additional confirmed details
- The cash movement balance trigger in upgrade 10 locks the affected cash-account row(s) and checks the resulting balance for inserts/updates/deletes. This is an important safeguard and must be retained when replacing direct cash-movement writes.
- The Fawry close function in upgrade 03 (the later signature including `p_funding_account`) uses a stable `fawry_topup` source ID equal to the close row ID and upserts/deletes that movement, preserving one top-up movement per close. The remaining risks are close-row concurrency and historical-chain consistency, not loss of top-up idempotency in the normal function path.
- A sale return can contain multiple refund payment rows. Therefore, simply changing every cash movement's `source_id` to the same return UUID would collide with the existing unique key on `(owner_id,source_type,source_id)`. Stable return traceability needs a per-refund-payment identity or an explicit return/payment link, not one shared source ID.
- The app's eight direct write handlers were re-counted in `accounting/app.js`; their exact locations are documented in `WRITE-PATH-HARDENING-DRAFT.md`. Read/select flows are not included in that count.

### Updated implementation priority
1. Design owner-aware relationship integrity for direct-write-capable child tables; add the missing sale-unit mapping guard.
2. Fix/validate the sale IMEI mapping algorithm against pre-upgrade unlinked sold units.
3. Move the eight direct-write handlers to atomic owner-derived RPCs; preserve the cash balance trigger and existing UI refresh behavior.
4. Harden NULL/type/range checks and Fawry close serialization/history policy.
5. Design return refund traceability with one stable identity per refund payment.
6. Stage and execute the two-user, IMEI legacy-data, cash concurrency, and full regression matrix before any production rollout.

No SQL has been run and no production data, grants, app code, or storefront resources have been changed.
