# AL GABAS PHONE ERP — Recovery & Static Audit Report
Date: 2026-11-02

Status: **static repository review only**. No Supabase production queries, SQL migrations, app deployments, or live data changes were performed.

## Repository state verified
- Repository: `ALGABAS26/al-gabas-phone`
- Production/default branch: `main`
- Review branch: `erp-security-fixes-draft`
- Compared refs: draft branch is 1 commit ahead of main and 0 behind.
- The only file added on the review branch at the time of comparison was `accounting/WRITE-PATH-HARDENING-DRAFT.md`; no application or SQL code changes were present on that branch.
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
