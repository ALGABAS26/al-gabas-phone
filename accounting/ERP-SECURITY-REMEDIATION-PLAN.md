# ERP Security Remediation — Implementation Specification

Date: 2026-11-02  
Status: design/documentation only; not deployed.  
Target branch: `erp-security-fixes-draft`  
Production/default branch: `main`

## 1. Safety and scope

- This document is a build specification, not executable SQL and not evidence of passing tests.
- No production SQL, grants, revokes, migrations, app deployment, or live data changes are authorized by this document.
- ERP scope only. Do not change storefront files, `public.products`, its policies, or its grants.
- Keep all work on the review branch until reviewed. Do not merge to `main` without explicit owner approval.
- Do not remove authenticated table privileges until every direct-write UI path has an equivalent tested RPC and the app no longer calls those direct writes.
- Derive the acting owner from `auth.uid()` inside each write RPC. Do not accept browser-supplied `owner_id` as authority.

## 2. Direct-write inventory from current `accounting/app.js`

The following eight lines/workflows were confirmed by scanning the current source for `.insert(` and `.upsert(` calls. Line numbers are approximate source positions and may move after edits.

| Current app location | Current table operation | Current browser-supplied fields | Replacement RPC (proposed) |
|---|---|---|---|
| Product form, around line 42 | INSERT `erp_products`, then optional INSERT `erp_product_units` | Product: name, category, condition, cost_price, sale_price, quantity, barcode. Unit: imei1, imei2, unit_barcode, purchase_price, status | `erp_create_product_with_unit` |
| Fawry form, around line 48 | INSERT `erp_fawry_transactions` | type, amount, commission, fee, reference, status, notes | `erp_record_fawry_transaction` |
| Cash opening form, around line 81 | UPSERT three `erp_cash_accounts` rows | account_code (drawer/vodafone_cash/instapay), account_name, opening_balance | `erp_save_cash_opening_balances` |
| Manual cash movement, around line 83 | INSERT `erp_cash_movements` | movement_date, direction, amount, description, source_type=manual, generated source_id, account_code | `erp_record_cash_movement` |
| Party form, around line 130 | INSERT `erp_parties` | party_type, name, phone, address, opening_balance, notes | `erp_create_party` |
| Party ledger form, around line 144 | INSERT `erp_party_transactions` | party_id, transaction_date, direction, amount, description | `erp_record_party_transaction` |
| Maintenance form, around line 229 | INSERT `erp_maintenance_orders` | generated ticket_no, customer_name, customer_phone, device_name, device_color, problem, accessories, estimated_cost, notes | `erp_create_maintenance_order` |
| Settings form, around line 237 | UPSERT `erp_shop_settings` on owner_id | shop_name, shop_name_en, phone, address, currency, invoice_prefix, invoice_note | `erp_save_shop_settings` |

### Important existing behavior to preserve

- Product form validates IMEI length/Luhn and duplicate IMEI values in the browser. Server validation must repeat all security/integrity checks; browser validation is only convenience.
- If a product has one or two IMEIs, current UI requires quantity exactly 1. Keep this rule unless the data model is deliberately redesigned.
- Current product creation is not atomic: product insert can succeed while unit insert fails. Replacement must create both in one database transaction.
- Fawry transaction creation refreshes Fawry list and dashboard after success.
- Cash opening saves all three configured accounts together and refreshes the cashbox.
- Manual cash movement creates a unique source UUID and refreshes the cashbox. Replacement must retain a stable source identity and the cash balance trigger.
- Party creation refreshes the party list. Party ledger creation refreshes the selected party ledger and party list.
- Maintenance intake currently generates a human-readable ticket number in the browser using date + timestamp suffix. Move generation to the server and enforce uniqueness; return the actual ticket number to display.
- Settings currently upserts by owner_id. Replacement must remain one row per owner and preserve EGP-only currency policy unless the schema explicitly supports another currency.

## 3. Proposed RPC contracts (design; verify exact table constraints before coding)

All functions must:
1. Be SECURITY INVOKER unless a documented, reviewed reason requires otherwise.
2. Set a safe `search_path` explicitly.
3. Obtain owner from `auth.uid()`; reject unauthenticated callers.
4. Reject SQL NULL, JSON null, missing required keys, wrong JSON types, invalid enum values, out-of-range numbers, and blank required text explicitly.
5. Use owner-scoped row lookups and locks where concurrent updates can race.
6. Return only the minimum identifiers/fields needed by the UI.
7. Be granted only to intended authenticated roles after exact signatures are inventoried. Audit default PUBLIC/anon EXECUTE separately; do not issue broad wildcard revokes.
8. Raise clear Arabic-safe validation errors where feasible; never return secrets or internal credentials.

### 3.1 `erp_create_product_with_unit`

Input design: product fields (name, category, condition, cost_price, sale_price, quantity, barcode) plus optional IMEI values. The browser must no longer send owner_id.

Server rules:
- Validate required name/category, nonnegative prices, integer quantity within supported bounds, and barcode uniqueness for the authenticated owner.
- Normalize IMEI digits consistently; accept only the supported 15-digit format and verify Luhn.
- Reject identical IMEI1/IMEI2 and reject duplicates against every existing unit/slot for the owner (cross-slot included).
- If any IMEI is supplied, require quantity = 1 under current UI/data semantics.
- Insert product and optional unit in one transaction. If any unit validation/insert fails, no product row remains.
- Return product id and barcode, and unit id if created.
- Test no-IMEI, one-IMEI, two-IMEI, invalid Luhn, duplicate same-slot, duplicate cross-slot, quantity mismatch, and rollback.

### 3.2 `erp_record_fawry_transaction`

Input design: type, amount, commission, fee, optional reference, status, optional notes.
- Validate allowed type/status values against actual schema constraints (do not guess enum lists).
- Validate amount/commission/fee explicitly for NULL, numeric type, sign, precision, and allowed bounds.
- Owner is server-derived.
- Preserve current Fawry list/dashboard refresh behavior.
- Verify whether this write affects daily-close accounting or only transaction history before defining side effects; do not silently add cash movements.

### 3.3 `erp_save_cash_opening_balances`

Input design: JSON array containing exactly the supported account codes and opening balances.
- Validate non-NULL array, exact expected number of entries, no duplicate account codes, all required codes present, and nonnegative numeric balances.
- Use the canonical account names already used by the UI: drawer / درج الكاش, vodafone_cash / فودافون كاش, instapay / إنستا باي.
- Preserve existing opening-balance guard: do not allow changing an opening balance after movements if current business rules prohibit it.
- Perform the three upserts atomically; partial save is not acceptable.
- Lock relevant account rows in deterministic account-code order if concurrent edits can occur.

### 3.4 `erp_record_cash_movement`

Input design: account_code, movement_date, direction, amount, description.
- Reject NULL/unsupported account code, invalid date, invalid direction, NULL/nonpositive amount, and blank/oversized description according to schema.
- Confirm the account belongs to the authenticated owner and is one of the supported cash accounts.
- Generate source identity on the server for source_type=manual; ensure idempotency/uniqueness behavior is intentional.
- Preserve the existing cash movement balance trigger and row-locking invariant. Do not duplicate or bypass its balance arithmetic.
- Ensure overdraw is rejected under concurrent requests as well as sequential requests.

### 3.5 `erp_create_party`

Input design: party_type, name, optional phone/address, opening_balance, optional notes.
- Validate party type against actual table constraint, required trimmed name, field lengths, and opening balance numeric range.
- Derive owner server-side.
- Preserve current UI refresh behavior.
- Determine whether opening balance requires a matching ledger transaction under existing accounting rules; do not create one implicitly without confirming current schema/function behavior.

### 3.6 `erp_record_party_transaction`

Input design: party_id, transaction_date, direction, amount, description.
- Reject NULL/invalid party ID/date/direction/amount.
- Lock and verify the party belongs to auth.uid() before insert.
- Validate amount > 0 and required description according to existing rules.
- Ensure the child row cannot reference another owner's party even if direct table access is attempted.
- Preserve ledger and party-list refresh behavior.

### 3.7 `erp_create_maintenance_order`

Input design: customer_name, optional customer_phone, device_name, optional device_color, problem, optional accessories, estimated_cost, optional notes.
- Generate ticket number inside the database using a collision-safe method and enforce unique owner/ticket (or globally unique ticket) according to the intended business rule.
- Validate required text and lengths, nonnegative estimated cost, and any actual status/default constraints.
- Derive owner server-side; do not accept owner_id or caller-selected status.
- Return ticket_no and order id.
- Preserve maintenance list refresh and Arabic success notice.

### 3.8 `erp_save_shop_settings`

Input design: shop_name, shop_name_en, phone, address, currency, invoice_prefix, invoice_note.
- Derive owner server-side and upsert by owner_id.
- Validate required values and field lengths.
- Enforce EGP if that is the current product requirement/schema rule; confirm before changing currency behavior.
- Ensure one settings row per owner and return the saved values needed by the UI.

## 4. Existing RPC hardening — separate from the eight new RPCs

Do not replace existing accounting RPCs unnecessarily. Audit and harden their current signatures and invariants:

- `erp_create_sale` and `erp_create_purchase`: reject NULL/non-array/empty item and payment payloads explicitly; validate every required item/payment key, JSON type, product id, quantity, price/cost, account code, and amount. Preserve one-transaction invoice/inventory/party-ledger/cash behavior.
- `erp_record_expense`: explicitly reject NULL account code and validate all required fields before insert.
- `erp_transfer_cash`: explicitly reject NULL source/destination codes; validate distinct allowed accounts and existence; preserve deterministic lock ordering and both linked movements atomically.
- `erp_save_fawry_daily_close`: reject NULL date and numeric fields; serialize same-owner/same-date writes; define a strict policy for editing historical closes when later closes exist; preserve stable top-up source identity and one movement per close.
- `erp_post_return`: retain exact invoice-line/product/IMEI guards. Design a stable per-refund-payment cash source identity or explicit return/payment mapping; do not assign the same return UUID to multiple rows if the source uniqueness constraint would collide.
- `erp_post_stock_count` and `erp_init_cash_accounts`: preserve existing authorization and invariants; review signatures/EXECUTE grants.

## 5. Relationship integrity and IMEI correctness

Before adding constraints:
1. Inventory actual primary keys, unique constraints, foreign keys, triggers, RLS policies, and grants from the complete schema and every upgrade in order.
2. Prepare read-only diagnostics for duplicate candidate keys, orphan references, cross-owner references, and duplicate IMEI values. Diagnostics must be SELECT-only.
3. Review diagnostic results and decide whether any legacy rows require repair. Never silently delete or reassign accounting/IMEI history.
4. Add `UNIQUE(owner_id,id)` parent keys only where supported by the actual schema, then owner-aware composite foreign keys where practical.
5. Add narrowly scoped BEFORE triggers for invariants not expressible as FKs, including same-owner/product consistency between sale invoice lines and linked product units.
6. Add the missing sale-unit mapping guard analogous to the purchase-unit guard, after checking actual schema and trigger ordering.
7. Fix/test sale IMEI mapping so it links only units transitioned to sold by the current transaction, not older sold-but-unlinked units.
8. Test return behavior against exact original invoice lines and serial units.

## 6. App migration sequence

Implement one workflow at a time on this review branch:
1. Add one SQL migration defining one RPC and its exact grants.
2. Review it against the complete current schema and existing naming/signatures.
3. Update only that UI handler to call the RPC; remove its direct table write.
4. Add loading/disabled state and clear failure handling without losing entered data.
5. Preserve the same successful refreshes and visible output.
6. Test success, invalid input, authorization failure, network/RPC failure, duplicate submission, and transaction rollback in staging.
7. Move to the next workflow only after the previous one is verified.

Recommended order: product+IMEI atomic create; party create/ledger; cash opening/manual movement; Fawry transaction; maintenance intake; settings. Revisit order if dependency analysis shows otherwise.

## 7. Least-privilege rollout — last, not first

- Inventory exact table privileges, schema privileges, default privileges, function signatures, SECURITY DEFINER/INVOKER mode, and EXECUTE grants.
- Separate table ACLs from RPC EXECUTE grants and trigger/helper function execution.
- After all eight direct writes are removed and tested, revoke only unnecessary client write privileges on ERP tables from exact roles/objects.
- Keep SELECT permissions required by current app reads.
- Do not revoke authenticated execution needed by the UI's RPCs.
- Verify anonymous and two-owner authenticated behavior.
- Never include `public.products` in ERP privilege changes.

## 8. Required staging regression suite (not run)

- All eight new RPCs: valid request, NULL/missing fields, invalid enum/type/range, wrong-owner references, duplicate submission, and failure rollback.
- Product + IMEI atomicity and all duplicate/Luhn/quantity cases.
- Cash balance invariant, overdraw prevention under concurrency, and opening-balance lock behavior.
- Fawry transaction and daily-close consistency, including concurrent same-day calls and historical edit policy.
- Sale/purchase split payments and atomic inventory/ledger/cash posting.
- Stock count and return workflows, including exact IMEI restoration and multiple refund payment rows.
- Two distinct authenticated users cannot read/write/reference each other's ERP rows.
- Maintenance ticket uniqueness and safe generation.
- Settings upsert uniqueness and currency policy.
- Existing read-only screens, exports, backup, and storefront remain unaffected.

## 9. Current status and release gates

- This is a design specification only.
- No SQL has been run against Supabase; no tests have been run; no production files have been modified.
- No changes to `main`, storefront, or `public.products`.
- Staging validation, full schema/ACL inventory, and owner review are required before production.
- Explicit owner approval is required before any production SQL, merge to `main`, or live deployment.
