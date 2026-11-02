# ERP Fifth-Pass Review — Sales, Purchases, Returns, Cash and Input Validation

**Repository:** ALGABAS26/al-gabas-phone  
**Reviewed ref:** main  
**Target branch for this note:** erp-security-fixes-draft  
**Review type:** Static source review only. No SQL was executed against Supabase. No production data, grants, policies, or storefront files were changed.

## Scope

Reviewed the source of:
- accounting/upgrade-03.sql
- accounting/upgrade-04.sql
- accounting/upgrade-05.sql
- accounting/upgrade-06.sql
- accounting/upgrade-07.sql
- accounting/upgrade-08.sql
- accounting/upgrade-09.sql
- accounting/upgrade-10.sql
- accounting/upgrade-11.sql

Previously reviewed later migrations (upgrade-12 through upgrade-14) remain relevant. Findings below must be reconciled against the complete deployed schema and live diagnostics before implementation.

## Findings requiring remediation or explicit acceptance

### F5-01 — JSON SQL NULL and JSON shape validation is incomplete
**Evidence:** upgrade-04 `erp_create_sale`, upgrade-06 `erp_create_purchase`, upgrade-08 `erp_post_stock_count`, and upgrade-08 `erp_post_return` use checks shaped like `jsonb_typeof(p_items)<>'array' OR jsonb_array_length(p_items)=0`. Sale/purchase also check payments similarly.

When the SQL argument itself is NULL, the boolean expression can evaluate to SQL NULL rather than TRUE, so the IF does not reject it. JSON arrays can also contain scalar/null elements or objects with missing/null keys; direct casts such as `(v_item->>'quantity')::integer`, UUID and numeric casts may raise generic errors, while comparisons involving NULL can fail to reject invalid values.

**Required design:** explicitly reject SQL NULL before JSON processing; require JSON array type and nonzero length; validate every element is an object; validate required keys and JSON value types; reject JSON null, blank IDs, fractional/out-of-range quantities, non-finite or negative monetary values, and invalid account codes before casting. Apply the same discipline to refund-payment arrays. Preserve useful Arabic error messages.

### F5-02 — Concurrent returns can over-return the same invoice line
**Evidence:** upgrade-08 `erp_post_return` locks the invoice header, then checks the already-returned quantity for each invoice item. The checked invoice-item rows are not explicitly locked, and the returned-quantity aggregate is not protected by a per-line serialization mechanism.

The header lock may serialize requests for one invoice when every call follows this exact path, but that guarantee must not be assumed without concurrency tests and verification of all return paths and isolation behavior. A robust design should lock the exact original invoice item rows in deterministic order before checking remaining returnable quantity, or use an equivalent database-enforced serialization/constraint strategy.

**Required regression tests:** two simultaneous returns against the same invoice line whose combined quantities exceed the original quantity; same test for sale and purchase; multi-line returns submitted in opposite item order; verify one transaction rolls back fully and stock/cash/party ledgers remain consistent.

### F5-03 — Sale IMEI mapping chooses a broad pool, not the exact units sold by this invoice
**Evidence:** upgrade-04 marks selected in-stock product units as sold, then inserts a sale invoice item. upgrade-11 trigger `erp_link_sold_units_to_sale_line` chooses sold, unlinked units for that owner/product ordered by creation time, limited by line quantity. It does not receive the exact unit IDs selected by the sale RPC.

A pre-existing sold-but-unlinked legacy unit can therefore be linked to a later sale line instead of the units transitioned by that sale. This is a source-level mismatch between the comment's “newly sold” claim and the actual predicate.

**Required design:** have the sale workflow carry the exact selected unit IDs into the line mapping within the same transaction, or use another transaction-scoped correlation mechanism that cannot select unrelated legacy units. Do not guess mappings for historical invoices. Add regression coverage with an older sold/unlinked unit and a new sale.

### F5-04 — Sale mapping table lacks a visible owner/product consistency guard
**Evidence:** upgrade-11 creates `erp_sales_invoice_item_units` with separate FKs to invoice item and product unit plus owner_id, but the migration shown does not add a trigger validating that the invoice line, unit, product, and owner all match. upgrade-12 contains a purchase-side unit-link guard; a corresponding sale-side guard must be verified/added.

**Required design:** BEFORE INSERT/UPDATE validation must ensure the invoice line and unit belong to the same owner and same product, and that the unit is in the expected state for the operation. Preserve uniqueness and return protections. Review all existing mapping rows before adding constraints.

### F5-05 — Owner-scoped RLS does not prove parent/child owner consistency
**Evidence:** migrations define independent owner_id values and ordinary single-column foreign keys for relationships including party transactions to parties, invoice items to products/invoices, stock-count items to counts/products, and return items to returns/products. A row can satisfy its own owner RLS check while referencing a parent row owned by a different user if the caller can supply the foreign UUID and table policies permit the write.

**Required design:** inventory all cross-table relationships and enforce same-owner relationships using composite unique keys/FKs where compatible, or carefully written trigger/RPC validation. Include nullable party references and all IMEI mapping tables. Do not add constraints until read-only diagnostics identify and resolve any existing mismatches.

### F5-06 — Fawry daily-close updates need per-owner/day serialization and chronology checks
**Evidence:** upgrade-03 `erp_save_fawry_daily_close` reads the prior close before inserting/updating the selected day and then upserts the close and its source-linked cash movement. It does not visibly lock a per-owner/day sequence or prevent a concurrent close for an adjacent date from validating against stale chronology.

The stable close UUID used as the top-up movement source is valuable for idempotent upsert behavior and must be preserved.

**Required design:** serialize close writes for the same owner (or a narrower safely ordered key), re-check predecessor/successor chronology under lock, and define what happens when an older close is edited after later closes exist. Preserve stable source identity and rollback atomicity. Test simultaneous adjacent-day closes and edits to a historical close.

### F5-07 — Explicit NULL checks are missing in several cash/account validation paths
**Evidence:** upgrade-03 `erp_save_fawry_daily_close` validates `p_funding_account NOT IN (...)` and numeric comparisons without first rejecting NULL. upgrade-09 transfer account-code validation also relies on `NOT IN` without explicit NULL rejection (amount is checked explicitly). upgrade-06 payment validation compares account code and amount but does not first require non-null values.

**Required design:** explicitly reject NULL for required enum/date/numeric/text fields before comparisons. Keep optional date/notes behavior intentional and documented. Add boundary tests for SQL NULL, JSON null, empty text, zero, negative, and out-of-range values.

### F5-08 — Return refund cash movements use random source IDs rather than a stable return/payment identity
**Evidence:** upgrade-08 `erp_post_return` inserts each sale-refund cash movement with `source_type='sale_return'` and `source_id=gen_random_uuid()`. This weakens traceability between a refund movement and its return/payment row and makes safe reconciliation harder.

**Required design:** use a durable identity for each refund payment (or a dedicated return-payment row with its own UUID), and reference that identity from the cash movement. Do not reuse one return UUID for multiple payment movements if the cash source uniqueness constraint is on owner/source_type/source_id.

### F5-09 — Purchase and return workflows need stronger item/payment object validation
**Evidence:** upgrade-06 `erp_create_purchase` and upgrade-08 `erp_post_return` cast fields directly from JSON and trust object shape. Purchase payment validation permits zero values (which are later skipped), and the return flow checks total refunded does not exceed item return value but does not visibly require the refund amount to match the intended refund policy.

**Required design:** define whether partial refunds are supported and enforce that policy explicitly; validate each payment entry as an object with required account and numeric amount; reject malformed, missing, null, and duplicate entries where appropriate. Ensure the sum of recorded payment rows matches the invoice/return header fields according to the documented business rule.

### F5-10 — Cash account trigger and transfer lock ordering must be preserved
**Evidence:** upgrade-09 transfer locks the two cash-account rows in stable account-code order and creates paired movements. upgrade-10 cash movement trigger locks affected cash accounts and prevents negative balances. These are important concurrency protections.

**Required design:** do not bypass or disable these triggers when migrating direct writes to RPCs. Review lock ordering across every new RPC to avoid introducing deadlocks. Add concurrent outflow/transfer tests and assert atomic rollback of both sides of a transfer.

## Safeguards confirmed in source and not to be removed

- upgrade-04 sale creation is transaction-scoped and updates stock, sale lines, payments, and cash movements together.
- upgrade-06 purchase creation updates stock, purchase lines, supplier ledger, payments, and cash movements together.
- upgrade-09 transfer creates paired outgoing/incoming movements under account locks.
- upgrade-10 cash movement and opening-balance triggers protect against negative balances.
- upgrade-10 blocks ambiguous IMEI returns until exact serial associations are available.
- upgrade-11 adds exact invoice-line association tables and return-state handling; the association-selection issue in F5-03 must be fixed without removing this feature.
- upgrade-12 purchase-side IMEI intake/mapping and return guards must be retained.
- The storefront `public.products` table and its policies are out of scope and must remain untouched.

## Implementation order (not executable SQL)

1. Obtain and review the read-only relationship/ACL/trigger diagnostics against the actual Supabase project.
2. Reconcile existing cross-owner links, duplicate identifiers, orphan rows, and legacy sold-but-unlinked IMEI units.
3. Specify regression tests for JSON validation, return concurrency, IMEI correlation, owner consistency, Fawry chronology, and cash concurrency.
4. Design the RPC/table constraints and migration sequence against the actual deployed schema version.
5. Move one browser direct-write workflow at a time to a tested RPC, preserving UI behavior and transaction atomicity.
6. Only after every direct-write path is removed and verified, prepare least-privilege grants/revokes for exact function signatures.
7. Never change storefront `public.products` or merge this review branch without explicit approval.

## Verification status

This document records static findings from repository source only. It does not claim that the SQL was run, that live data was inspected, that migrations were applied, or that runtime tests passed.


## Upgrade 23 implementation note — pending staging verification

A draft implementation now exists in `accounting/upgrade-23.sql`, with a rollback-based staging test in `accounting/tests/upgrade-23-sale-imei-regression.sql`.

It addresses F5-03 and F5-04 at source level:

- The sale RPC captures the exact unit UUIDs returned by the same UPDATE that changes those units from `in_stock` to `sold`.
- Those exact UUIDs are stored on the sale line in the additive `imei_unit_ids uuid[]` column.
- The existing AFTER INSERT trigger maps only those supplied UUIDs; it no longer searches the broad pool of all sold/unlinked units.
- Tracked-product sale lines fail closed if the exact number of selected UUIDs is missing, duplicated, already mapped, in the wrong state, or belongs to another owner/product.
- A new mapping guard checks invoice-line owner/product and unit owner/product/status before mapping writes.
- The sale RPC signature and accounting side effects (invoice, stock, split payments and cash movements) are preserved.
- Sale JSON arguments now explicitly reject SQL NULL, non-array payloads, null/scalar item/payment elements, missing IDs, malformed quantities/prices and invalid payment account codes before casts.

The regression test requires a synthetic user's test product with at least one older sold-but-unlinked unit and one in-stock unit. It checks that the new sale links the newly selected in-stock unit and leaves the legacy unit untouched; it also checks SQL NULL and malformed JSON rejection.

**Important limitations:** this is a proposed migration, not an applied database change. The test has not been run. Existing historical sale mappings are not guessed or backfilled. Before staging application, confirm the deployed schema includes the referenced sale-unit mapping table and the existing trigger/function definitions from upgrades 11–12. After staging, run the regression plus the full sales/returns/accounting suite and inspect the resulting sale-line reads/exports for compatibility with the additive column.

This source-level implementation does not resolve concurrent return serialization, purchase/return JSON validation, owner-aware foreign keys, Fawry chronology, or ACL revocation. Those remain open.


## Upgrade 24 implementation note — return quantity serialization

A draft implementation now exists in `accounting/upgrade-24.sql`, with a rollback-based staging regression script in `accounting/tests/upgrade-24-return-regression.sql`.

The replacement keeps the existing `erp_post_return(text,text,uuid,date,text,jsonb,jsonb)` signature and preserves the existing business effects:
- Sale returns restore product stock, insert return header/items, and create the same per-payment cash outflows.
- Purchase returns reduce product stock and retain the supplier party-ledger decrease entry.
- Existing return-item triggers remain in place, including exact sale IMEI return-state handling.
- Purchase-return refund behavior remains unchanged (no cash refund rows).

The function continues to lock the sale/purchase invoice header with `FOR UPDATE`, which serializes calls through this RPC for the same invoice. It additionally locks every requested original invoice line in ascending UUID order before checking cumulative returned quantity. This makes line-level serialization explicit and avoids order-dependent line-lock acquisition for multi-line returns. SQL NULL and malformed item/payment JSON are rejected before casts or writes.

The staging regression script covers partial sale and purchase returns followed by rejected over-returns, verifies the rejected attempt did not change returned quantity or sale inventory, and checks SQL NULL rejection. It includes a separate two-session concurrency procedure because the single-transaction test cannot simulate two concurrent sessions.

**Pending verification:** the migration and test have not been executed or parsed by PostgreSQL in this chat. The two-session concurrency procedure, full IMEI return suite, cash/party-ledger assertions, and staging schema compatibility remain unverified. The existing random UUID cash source identity for each sale refund payment is deliberately preserved here and remains a separate traceability improvement. No production SQL was run.


## Upgrade 25 implementation note — Fawry close chronology

A draft implementation now exists in `accounting/upgrade-25.sql`, with a rollback-based staging regression script in `accounting/tests/upgrade-25-fawry-chronology-regression.sql`.

The replacement keeps the existing RPC signature and stable close UUID as the `fawry_topup` cash-movement `source_id`. It adds:
- Explicit rejection of NULL date, required numeric balances, and funding account; non-finite and negative numeric values are rejected.
- A transaction-level advisory lock scoped to the authenticated owner, serializing all Fawry close writes for that owner.
- Revalidation of the nearest earlier close before writing.
- A successor check so editing/inserting a historical close cannot silently break the next saved close's opening balance.
- Existing upsert and source-linked cash movement behavior is retained.

The staging regression covers predecessor/successor continuity, rejection of a historical edit that breaks the next close, and NULL input rejection. It also documents a two-session adjacent-day concurrency procedure.

**Pending verification:** migration and test have not been run or parsed by PostgreSQL in this chat. The two-session test, cash-balance trigger interaction when a nonzero top-up is saved/edited/deleted, and staging schema compatibility remain unverified. The owner advisory lock only coordinates callers using this RPC; direct table writes remain possible under the existing authenticated table grants and must be addressed in the broader write-path/ACL hardening package.


## Upgrade 26 implementation note — NULL-safe RPC validation

A draft implementation now exists in `accounting/upgrade-26.sql`, with a rollback-based staging regression script in `accounting/tests/upgrade-26-rpc-validation-regression.sql`.

The migration replaces three existing RPCs without changing their signatures:

- `erp_record_expense`: explicitly rejects NULL/blank category or description, NULL/non-finite/non-positive amount, and NULL/invalid account before writing either the expense or its cash outflow.
- `erp_transfer_cash`: explicitly rejects NULL/invalid source and destination accounts, same-account transfers, and NULL/non-finite/non-positive amount. It retains stable account-row locking, available-balance validation, the transfer record, and paired cash movements.
- `erp_create_purchase`: explicitly rejects SQL NULL/non-array/empty item lists, NULL/non-array payments, malformed array elements, missing/invalid product IDs, quantities and costs, malformed IMEI-unit arrays, and malformed payment entries before invoice or inventory writes. It preserves weighted-average product cost, inventory receiving, IMEI Luhn validation and purchase-line mappings, supplier ledger entries, payment rows, and cash outflows.

Client EXECUTE is explicitly revoked from PUBLIC and anon and granted to authenticated for these three RPC signatures. This does not remove authenticated direct table DML; that remains a separate ACL/dependency-hardening task.

The regression script checks expense and transfer NULL inputs, purchase NULL arrays/elements, and that rejected purchase requests do not change product quantity or cash-movement count. It also documents positive-path and IMEI staging checks.

**Pending verification:** no PostgreSQL parser/runtime execution occurred in this chat. The purchase RPC body is a source-preserving hardening rewrite and still needs comparison against the live staging schema and positive-path regression coverage, including weighted-average cost, supplier balance, payment/cash linkage, and IMEI unit mapping. No production SQL was run.


## Static EXECUTE privilege review — legacy function exposure

A static source review of migration files `upgrade-02.sql` through `upgrade-12.sql` found that the following client-callable RPCs were granted to `authenticated` but their defining migrations did not explicitly revoke EXECUTE from `PUBLIC` or `anon`:

- `erp_save_fawry_daily_close(date,numeric,numeric,numeric,numeric,text)` (later replaced by the seven-argument form in upgrade 03 and hardened in upgrade 25)
- `erp_init_cash_accounts()`
- `erp_create_sale(...)` (the exact deployed signature is captured by the ACL audit; upgrade 23 later replaces the current signature and revokes PUBLIC/anon)
- `erp_create_purchase(text,date,uuid,numeric,text,jsonb,jsonb)` (hardened in upgrade 26)
- `erp_record_expense(date,text,numeric,text,text)` (hardened in upgrade 26)
- `erp_post_stock_count(date,text,jsonb)`
- `erp_post_return(text,text,uuid,date,text,jsonb,jsonb)` (hardened in upgrade 24)
- `erp_transfer_cash(date,text,text,numeric,text)` (hardened in upgrade 26)

The trigger/helper functions introduced in upgrades 10–12 also lack explicit EXECUTE revokes in their original migrations. Trigger functions cannot be invoked as ordinary SQL functions, but their ACLs should still be classified and tightened where appropriate. The pure IMEI Luhn helper is a separate low-risk helper, not a browser RPC.

This is a **static migration-source finding**, not proof that the current production database still has these ACLs: later migrations, manual grants, default privileges, ownership, and role membership can change effective permissions. The existing SELECT-only `ERP-ACL-EXECUTION-DEPENDENCY-AUDIT.sql` remains the authoritative staging evidence collection. No broad revoke migration has been drafted because exact function signatures, PUBLIC/anon effective privileges, role membership, trigger dependencies, and default ACLs must be reviewed first.

Upgrade 14's `erp_my_shop_profile()` is the only SECURITY DEFINER function found in the reviewed migration range. It explicitly revokes PUBLIC/anon and grants authenticated, but its staging behavior and safe search_path configuration remain part of the separate SECURITY DEFINER review. No production ACL changes were made.


## Upgrade 27 implementation note — SECURITY DEFINER shop profile disclosure

Static review of `upgrade-14.sql` found that `erp_my_shop_profile()` is SECURITY DEFINER and returns subscription status/expiry for every active membership role. This is broader than the table-level subscription SELECT policy introduced in the same migration, which permits only shop owners and admins. An active viewer/accountant/sales/technician could therefore receive subscription metadata through the definer function despite lacking direct subscription-table access.

A draft fix now exists in `accounting/upgrade-27.sql`: it retains the function signature, membership-scoped shop profile, SECURITY DEFINER behavior, and authenticated-only EXECUTE, but returns subscription status and expiry only when the current member role is `owner` or `admin`. It also fixes the function search_path to `pg_catalog, public, pg_temp` and keeps relation references schema-qualified.

The rollback staging regression in `accounting/tests/upgrade-27-shop-profile-privilege-regression.sql` verifies that a viewer receives NULL subscription fields while an admin receives the expected subscription metadata. It requires an isolated synthetic auth user with no pre-existing shop memberships.

**Pending verification:** no SQL parser/runtime execution occurred. Test the function under real authenticated JWT claims and confirm the application does not rely on subscription metadata being exposed to non-admin roles. Multi-Shop onboarding remains disabled; this fix does not make the ERP tenant-ready.


## Upgrade 26 source-to-source comparison — purchase RPC

A direct comparison was completed between the original `erp_create_purchase(text,date,uuid,numeric,text,jsonb,jsonb)` in `upgrade-12.sql` and its hardened replacement in `upgrade-26.sql`.

The replacement retains the original successful-path operations and order:
- Supplier lookup remains owner-scoped and row-locked.
- Product rows remain owner-scoped and locked before stock/cost calculations.
- Weighted-average cost calculation and product quantity update are retained.
- Purchase invoice and invoice-item rows retain the same values and relationships.
- IMEI normalization, Luhn checks, product-unit inserts, and purchase-line unit mappings are retained.
- Supplier ledger increase/decrease entries retain their original amounts and descriptions.
- Purchase payment rows and matching cash outflow rows retain their source identity and account/date behavior.
- The RPC still returns the purchase invoice UUID and retains the original signature.

The replacement adds pre-write validation for SQL NULL/non-array JSON payloads, item/payment object shapes, UUID/quantity/cost syntax, IMEI element types, account codes, and finite/nonnegative numeric values. This was a static source comparison only; it does not prove equivalence against the deployed database or every client payload.

**Still required in staging:** run the positive-path purchase regression with ordinary and IMEI-tracked products; assert weighted-average cost, supplier balance, invoice totals, payment rows, cash movement linkage, IMEI uniqueness/mapping, and full rollback on a rejected late-stage IMEI insert. PostgreSQL parsing/runtime remains unverified.

## Owner-aware foreign-key preflight audit

Added `accounting/ERP-OWNER-FK-PREFLIGHT-AUDIT.sql`.

The script is SELECT-only. It inventories foreign keys between `public.erp_*` tables where both sides have `owner_id`, flags relationships whose FK column mapping omits `owner_id`, and emits separate orphan/cross-owner SELECT checks for manual execution. It also inventories existing primary/unique keys to support review of candidate composite constraints.

The script does not execute generated SQL, alter schema/data/grants, inspect `public.products`, or prove that a candidate relationship is exploitable. Nullable links and intentional relationship semantics must be reviewed. No composite FK migration has been drafted; actual staging output and row-level checks are required first.


## Consolidated staging runbook and current app source scan

Added `accounting/ERP-STAGING-SECURITY-VALIDATION-RUNBOOK.md` to collect the remaining steps in one ordered staging procedure: read-only relationship/owner-FK/ACL/tenant evidence capture, sequential application of upgrades 15–27 with matching rollback regressions, additional positive-path and two-session concurrency tests, application smoke tests, and release gates.

A fresh static scan of `accounting/app.js` on this branch found the expected 17 RPC names, including the purchase/sale/return, stock-count, cash, Fawry, maintenance, settings, expense, party, and shop-profile calls. The scan found no direct `.from(...).insert/upsert/update/delete` patterns. This is a regex/source scan only, not proof of complete absence of all direct write paths or runtime behavior.

**Execution blocker:** a Supabase connection is not currently active in this session. The Supabase integration has been surfaced for the user to connect. Until it is connected to the intended separate staging project, no live schema evidence, migration execution, PostgreSQL parse/runtime test, or concurrency test can truthfully be reported. The runbook explicitly forbids production execution. No ACL revoke migration or composite-FK migration has been authored.
