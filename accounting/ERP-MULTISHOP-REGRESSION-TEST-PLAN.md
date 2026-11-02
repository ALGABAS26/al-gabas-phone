# AL GABAS ERP — Multi-Shop Isolation and Accounting Regression Test Plan

**Status:** planned tests; none executed by this document.  
**Environment:** separate Supabase test project with synthetic data only.

## 1. Test fixture

Create two independent tenants:
- Shop A: owner A, admin A, accountant A, sales A, inventory A, technician A, viewer A.
- Shop B: owner B, admin B, accountant B, sales B, inventory B, technician B, viewer B.
- Add one test user who is an active member of both shops to test switching.
- Add one invited/suspended member and one revoked member.
- Seed distinct products, serial units, parties, invoices, cash accounts, expenses, maintenance tickets, returns, stock counts, Fawry closes, and settings in each shop.
- Use synthetic data only. Never copy live customer or payment data into tests.

## 2. Tenant isolation tests

For every tenant-owned table, test SELECT, INSERT, UPDATE, DELETE through the REST/Data API as each role. Expected: only explicitly allowed shop-scoped reads are visible; browser direct writes are denied after the RPC cutover.

Tables to cover:
- `erp_products`, `erp_product_units`
- `erp_sales_invoices`, `erp_sales_invoice_items`, `erp_sales_payments`, `erp_sales_invoice_item_units`
- `erp_purchase_invoices`, `erp_purchase_invoice_items`, `erp_purchase_payments`, `erp_purchase_invoice_item_units`
- `erp_parties`, `erp_party_transactions`
- `erp_cash_accounts`, `erp_cash_movements`, `erp_cash_transfers`
- `erp_fawry_transactions`, `erp_fawry_daily_closings`
- `erp_expenses`
- `erp_stock_counts`, `erp_stock_count_items`
- `erp_returns`, `erp_return_items`
- `erp_maintenance_orders`, `erp_shop_settings`
- `erp_shops`, `erp_shop_memberships`, `erp_shop_subscriptions`, `erp_shop_audit_log`

### Required negative cases

1. User A requests Shop B rows by REST filter: no Shop B data is returned.
2. User A forges Shop B `shop_id` on INSERT/UPDATE/RPC input: request fails.
3. User A changes the browser JavaScript to remove shop filters: RLS still prevents cross-shop reads.
4. User A uses a Shop B product, party, invoice line, cash account, IMEI unit, return, or stock count ID in a Shop A operation: request fails.
5. User with no active membership calls any shop RPC: fails.
6. Suspended membership attempts read/write: fails according to approved suspension policy.
7. Revoked membership attempts another request with a previously cached shop ID: fails immediately at database boundary.
8. User belonging to A and B switches A → B → A: no records, selections, cached totals, or pending form values leak across shops.
9. A user cannot discover another shop by guessing UUIDs or slugs.
10. An invited membership cannot access the shop before acceptance and activation.

## 3. Role authorization tests

For each RPC, test every role, including unauthorized roles. A UI-hidden button is not a passing test.

| Workflow | Allowed roles | Must fail |
|---|---|---|
| Create shop | New authenticated user; creates self as owner | Existing member cannot silently create membership for another user |
| Invite/manage members | owner; approved admin subset | accountant, sales, inventory, technician, viewer |
| Transfer ownership | owner only | all other roles |
| Create product / IMEI | owner, admin, inventory | accountant, sales, technician, viewer |
| Sale | owner, admin, accountant, sales | inventory, technician, viewer |
| Purchase | owner, admin, accountant, inventory | sales, technician, viewer |
| Expense | owner, admin, accountant | sales, inventory, technician, viewer |
| Cash movement/transfer/opening | owner, admin, accountant | sales, inventory, technician, viewer |
| Fawry transaction/close | owner, admin, accountant | sales, inventory, technician, viewer |
| Stock count | owner, admin, inventory | accountant (write), sales, technician, viewer |
| Sales return | owner, admin, accountant, sales | inventory-only user, technician, viewer |
| Purchase return | owner, admin, accountant, inventory | sales-only user, technician, viewer |
| Maintenance intake/update | owner, admin, technician; sales intake-only | accountant unless approved, inventory, viewer |
| Shop settings | owner, admin | all other roles |
| Subscription management | owner; admin read-only | all other roles |
| Export full shop backup | owner, admin | all other roles unless explicitly approved |

## 4. Foreign-key and relationship tests

- Every invoice line references a product in the same shop.
- Every payment references an invoice in the same shop.
- Every party transaction references a party in the same shop.
- Every product unit references a product in the same shop.
- Purchase/sale IMEI mappings reference both a line and a unit in the same shop and same product.
- Every return references an original invoice and exact invoice line in the same shop.
- Return item quantity cannot exceed the remaining quantity of its original invoice line under concurrent calls.
- Stock-count items reference a stock count and product in the same shop.
- Cash transfer debit and credit legs belong to the same shop and accounts belong to that shop.
- Maintenance ticket and related product/device references remain in the same shop.
- Cross-shop FK attempts fail even when the caller is owner/admin in the source shop.

## 5. Accounting invariants

### Sales and purchases
- Invoice header, lines, inventory, IMEI mapping, party ledger, payment rows, and cash movements commit or roll back together.
- SQL NULL, JSON null, empty arrays, scalar array elements, missing keys, wrong types, fractional quantities, negative values, invalid UUIDs, and invalid account codes are rejected before unsafe casts.
- Split payments sum and post according to current accounting rules.
- Duplicate submission cannot create duplicate invoices or cash movements where idempotency is required.

### Cash
- Opening balances remain editable only under the approved existing business rule.
- Concurrent outflows cannot overdraw an account.
- Transfers lock accounts in deterministic order, create both legs atomically, and preserve combined cash.
- Same-account and cross-shop transfers fail.
- Existing cash movement balance triggers remain enabled and effective.

### IMEI
- Luhn validation accepts valid 15-digit examples and rejects invalid length/check digits.
- Same-row IMEI1=IMEI2 is rejected.
- Duplicate values across IMEI1/IMEI2 and across units in one shop are rejected, including concurrent inserts.
- Product + serial-unit creation is atomic.
- Purchase mapping validates shop, product, and purchase line.
- Sale mapping links only units transitioned to sold by the current sale transaction, never legacy sold-but-unlinked units.
- Sale mapping validates shop and product on both sides.
- Returns update only serial units linked to the exact original invoice line.
- Concurrent returns cannot return the same serial or exceed line quantity.

### Fawry
- Same-shop same-date close is serialized.
- Top-up movement has one stable source identity per close and is not duplicated on retry.
- Historical close edit policy is enforced against later closes.
- Cross-shop close or funding account is rejected.

### Other workflows
- Expense posts only to an allowed cash account in the same shop.
- Party opening balance follows the approved ledger policy.
- Maintenance ticket number is collision-safe and unique in the intended scope.
- Shop settings are unique per shop.
- Stock count posting is atomic and shop-scoped.

## 6. Subscription and lifecycle tests

- Active plan allows only its defined entitlements and limits.
- Trial expiry, past_due, grace, suspended, cancelled, and expired states follow the approved write/read/export policy.
- Client-forged subscription status or plan code has no effect.
- Membership role changes take effect on the next database request.
- Removing a user from a shop revokes table, RPC, storage, and export access.
- Shop closure preserves data according to the retention policy and cannot be reversed by a non-owner.

## 7. Frontend and device tests

- Shop switcher lists only the caller's active memberships.
- First login with one shop remains simple and defaults to that shop.
- A multi-shop user can switch without stale rows or form data.
- Role-aware navigation is consistent with database authorization.
- Android Chrome and installed APK both use the same tenant-aware code.
- Network failure during shop switch does not show the previous shop's data as if it belonged to the new shop.
- Product scan, IMEI scan, invoice print, reports, exports, and backup remain scoped to the selected shop.
- Storefront remains unchanged and continues using its existing `public.products` data and policies.

## 8. Evidence required for each test

Record:
- migration commit and database version;
- test user, shop, role, and membership status;
- exact RPC or REST operation;
- expected and actual result;
- SQLSTATE/error class for rejected operations;
- before/after row counts and accounting control totals;
- concurrency test method and result;
- screenshot/log reference with secrets and personal data removed.

## 9. Release gate

No production cutover unless every required test passes in a separate restored test project, all critical accounting control totals match, the backup restore rehearsal succeeds, and the owner explicitly approves the release.
