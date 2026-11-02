# Tenant isolation implementation matrix

Status: audit only. This is not authorization to change production policies.

## Frontend access inventory (accounting/app.js)

The current frontend directly accesses these ERP tables through Supabase REST:
- `erp_products`
- `erp_product_units`
- `erp_fawry_transactions`
- `erp_fawry_daily_closings`
- `erp_cash_accounts`
- `erp_cash_movements`
- `erp_sales_invoices`
- `erp_parties`
- `erp_party_transactions`
- `erp_purchase_invoices`
- `erp_purchase_invoice_items`
- `erp_maintenance_orders`
- `erp_shop_settings`
- `erp_return_items`
- `erp_stock_counts`
- `erp_stock_count_items`
- `erp_returns`

The current frontend calls these RPCs:
- `erp_my_shop_profile` — read-only current shop metadata.
- `erp_save_fawry_daily_close`
- `erp_init_cash_accounts`
- `erp_transfer_cash`
- `erp_create_sale`
- `erp_create_purchase`
- `erp_record_expense`
- `erp_post_stock_count`
- `erp_post_return`

The frontend currently has no `shop_id` references. It therefore does not select an active shop, pass shop context to business writes, or filter direct table operations by tenant. Adding a shop selector alone would not provide security.

## Full table inventory from schema and migrations

| Table | Current frontend access | Tenant migration requirement |
|---|---|---|
| erp_products | Direct REST | RLS + scoped CRUD + composite keys |
| erp_product_units | Direct REST | RLS + scoped CRUD + product relation |
| erp_fawry_transactions | Direct REST | RLS + scoped CRUD |
| erp_fawry_daily_closings | Direct REST/RPC | RLS + scoped RPC |
| erp_cash_accounts | Direct REST/RPC | RLS + scoped opening/initialization |
| erp_cash_movements | Direct REST/RPC | RLS + scoped posting and balance triggers |
| erp_sales_invoices | Direct REST/RPC | RLS + scoped sale RPC |
| erp_sales_invoice_items | Nested/direct invoice relation | RLS + composite invoice/product links |
| erp_sales_payments | Invoice relation/RPC | RLS + scoped payment posting |
| erp_sales_invoice_item_units | Invoice/IMEI relation | RLS + scoped invoice/unit links |
| erp_purchase_invoices | Direct REST/RPC | RLS + scoped purchase RPC |
| erp_purchase_invoice_items | Direct/nested relation | RLS + composite invoice/product links |
| erp_purchase_payments | Purchase relation/RPC | RLS + scoped payment posting |
| erp_purchase_invoice_item_units | Purchase/IMEI relation | RLS + scoped invoice/unit links |
| erp_parties | Direct REST | RLS + scoped CRUD |
| erp_party_transactions | Direct REST/RPC effects | RLS + scoped ledger posting |
| erp_maintenance_orders | Direct REST | RLS + scoped CRUD |
| erp_shop_settings | Direct REST | RLS + scoped CRUD |
| erp_expenses | Direct REST/RPC | RLS + scoped expense RPC |
| erp_stock_counts | Direct REST/RPC | RLS + scoped stocktake RPC |
| erp_stock_count_items | Direct/nested relation | RLS + scoped stocktake/product links |
| erp_returns | Direct REST/RPC | RLS + scoped return RPC |
| erp_return_items | Direct REST/RPC | RLS + scoped invoice-line/unit links |
| erp_cash_transfers | Direct REST/RPC | RLS + scoped transfer RPC |
| erp_shops | Profile RPC/metadata | Membership-gated reads and owner management |
| erp_shop_memberships | Profile metadata | Self-read + owner/admin role management |
| erp_shop_subscriptions | Profile metadata | Self-read + server-controlled billing changes |
| erp_shop_audit_log | Metadata | Tenant read policy + server-only writes |

## Critical release blockers found

1. No `shop_id` usage exists in the frontend.
2. Existing business RPCs are owner-scoped and do not validate shop membership or role.
3. Direct REST table operations remain a separate attack surface; changing RPCs alone is insufficient.
4. The migration must cover child tables and IMEI link tables, not only the main invoice/product tables.
5. Shop metadata SELECT access does not imply safe shop creation, invitation, role management, or billing.
6. Existing owner_id policies must not be removed until the complete shop-aware policy and RPC set is ready to deploy atomically.

## Required test matrix before production cutover

Create two synthetic shops (A and B), each with distinct users and records. Test with authenticated users for:
- SELECT, INSERT, UPDATE, DELETE on every table listed above.
- All nine frontend RPCs, including forged shop IDs and wrong-role users.
- Foreign references: product, party, invoice, invoice line, cash account, and IMEI unit from the other shop.
- Cash transfers, returns, stocktakes, and purchase/sale posting under concurrent requests.
- Membership revocation and suspended/expired subscription behavior.
- JSON/CSV exports, backup, and storage URLs.

Expected result: every cross-shop or unauthorized operation fails at the database boundary, even if the client is modified to bypass the UI.

## Scope guard

Do not change `public.products`, the storefront, or the live production RLS/RPCs as part of this audit. Build and validate the complete tenant migration on a separate Supabase test project first.
