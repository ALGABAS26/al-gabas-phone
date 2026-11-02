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
