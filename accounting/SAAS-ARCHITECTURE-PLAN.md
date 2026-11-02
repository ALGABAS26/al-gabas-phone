# AL GABAS STORE — SaaS Multi-Shop Architecture Plan

Status: phased implementation in progress. Upgrades 13 and 14 have been reported successfully executed by the owner. They provide shop metadata, backfill, and read-only access to the current user's shop profile. Existing ERP RLS/RPC authorization is still owner-based; production multi-shop access is not enabled.

## 1. Current boundary

The ERP is currently single-owner. ERP tables use `owner_id` tied to `auth.users(id)`; current RLS and RPC logic are built around that owner. This is suitable for the current shop but is not safe to share with other shops by merely creating more logins or sharing the current login.

The public storefront table `public.products` is separate and must remain untouched by ERP/SaaS migrations.

## 2. Target model

Introduce a first-class shop (tenant) and explicit memberships:

- `erp_shops`: one row per shop; UUID id, display name, slug, contact details, currency, timezone, status, created_at.
- `erp_shop_memberships`: shop_id, user_id, role, membership status, created_at; unique(shop_id,user_id).
- Roles: `owner`, `admin`, `accountant`, `sales`, `inventory`, `technician`, `viewer`. Permissions are server-enforced, not merely hidden in the interface.
- `erp_shop_subscriptions`: shop_id, plan_code, status, starts_at, expires_at, grace_until, provider_reference (nullable), created_at. Never store card data.
- `erp_shop_audit_log`: shop_id, actor_user_id, action, entity/table, entity_id, timestamp, safe metadata. Do not log passwords, tokens, or full payment secrets.

Keep existing `owner_id` temporarily as the historical creator/legacy ownership field. Add `shop_id` to every ERP business table and backfill all existing rows to one initial shop owned by the current account. Only after verified backfill should RLS/RPCs move from owner-only checks to membership checks.

## 3. Tables in the current ERP scope

The current SQL set defines these ERP tables, all of which must become shop-scoped:

- erp_products, erp_product_units
- erp_sales_invoices, erp_sales_invoice_items, erp_sales_payments, erp_sales_invoice_item_units
- erp_purchase_invoices, erp_purchase_invoice_items, erp_purchase_payments, erp_purchase_invoice_item_units
- erp_parties, erp_party_transactions
- erp_cash_accounts, erp_cash_movements, erp_cash_transfers
- erp_fawry_transactions, erp_fawry_daily_closings
- erp_maintenance_orders
- erp_shop_settings
- erp_expenses
- erp_stock_counts, erp_stock_count_items
- erp_returns, erp_return_items

Any future table, storage object, export, or background job must carry and enforce shop scope too.

## 4. Security invariants (must all hold)

1. Every row belongs to exactly one shop; `shop_id` is NOT NULL after migration.
2. A user can read or mutate a row only if an active membership exists for that row's shop.
3. Client-supplied shop_id is never trusted by itself. Every RPC validates that the authenticated user is an active member of the requested shop and has the required role.
4. Cross-shop foreign keys are prevented. Use composite unique keys and foreign keys such as (shop_id, product_id), not only globally referenced IDs where practical.
5. Every RPC derives/validates shop scope before selecting, locking, updating, or inserting business rows.
6. RLS is enabled and forced where appropriate; policies cover SELECT, INSERT, UPDATE, DELETE. SECURITY DEFINER functions use a fixed safe search_path and explicit authorization checks.
7. Storage paths and signed URLs are shop-scoped. Backups and CSV exports include only the active shop.
8. A suspended or expired subscription blocks new business writes according to plan/grace policy, but owners retain read/export access to their own data for a documented recovery period.
9. No shared default owner account. Each shop owner signs up with their own Auth identity.
10. Audit sensitive actions: role changes, subscription changes, stock adjustments, returns, cash movements, exports, and settings changes.

## 5. Migration sequence (future, not approved or executed)

A. Build a separate Supabase test project and restore a copy of the current schema with synthetic data only.

B. Add shops, memberships, subscription and audit tables. Create one initial shop for the current owner. Add nullable shop_id columns to every ERP table.

C. Backfill shop_id using the current owner_id mapping. Verify row counts, orphan rows, invoice-line relations, IMEI mappings, cash movement links, and return links.

D. Add shop-scoped unique constraints and composite foreign keys. Keep legacy constraints until all new constraints pass.

E. Replace RLS policies table-by-table with active membership policies. Add role-specific write policies.

F. Replace every business RPC with shop-aware authorization and role checks. This includes sale, purchase, expense, Fawry close, cash transfer, return, stocktake, and cash initialization. Never deploy a partial set.

G. Update frontend: shop onboarding, shop switcher, role-aware navigation/actions, subscription status, and clear expired/suspended messages. Do not store authorization decisions only in local storage.

H. Run isolation tests with at least two shops and multiple roles. Attempt cross-tenant reads, direct REST writes, forged shop IDs, foreign invoice/product IDs, exports, and RPC calls. Every unauthorized attempt must fail.

I. Only after all checks pass, plan production cutover with a verified backup and rollback path.

## 6. Required automated isolation tests

- Shop A user cannot SELECT Shop B products, invoices, customers, units, settings, or cash movements.
- Shop A user cannot INSERT/UPDATE/DELETE any Shop B row through REST or RPC.
- A Shop A invoice cannot reference a Shop B product, payment, party, or IMEI unit.
- A Shop A return cannot return Shop B invoice lines or serials.
- Cash transfers cannot debit one shop and credit another.
- A viewer cannot post sales, purchases, expenses, returns, or cash movements.
- A sales role cannot change subscription, memberships, or shop ownership.
- Expired/suspended shops cannot perform prohibited writes.
- Exports and backups contain only the selected shop's records.
- Removing a membership immediately revokes access, including RPC and storage access.

## 7. Subscription and commercial readiness

Before charging customers, define plan limits (users, products, branches, storage, support), billing terms, cancellation, grace period, data export, deletion/retention, and support process. Subscription enforcement must run server-side. A hidden menu item is not a security boundary.

## 8. Release gate

Do not apply tenant migrations to the current production Supabase project until:
- the complete SQL migration set has been reviewed and tested on a separate Supabase project;
- all existing rows have a verified one-shop backfill;
- RLS/RPC isolation tests pass;
- a restorable backup and rollback plan exist;
- the shop owner explicitly approves the production cutover.

## 9. Upgrade 13 — additive foundation (owner confirmed run)\n\n`upgrade-13.sql` creates the shop, membership, subscription, and audit tables; adds nullable `shop_id` columns to the current ERP tables; seeds one initial shop per existing ERP owner; backfills existing rows; and aborts the transaction if any owner-owned row remains unassigned. Existing `owner_id` RLS policies and business RPCs are deliberately left unchanged. New management tables have RLS enabled without client policies, so they remain inaccessible from the app until a later reviewed upgrade adds controlled access.\n\nThe owner reports that upgrades 08–13 were executed successfully in order. Upgrade 14 adds `erp_my_shop_profile()` and controlled SELECT policies for a user's own shop metadata; the owner reports it was also executed. It is not the multi-tenant release: do not invite another shop or share the current login. A later upgrade must add shop-aware write defaults, membership authorization, composite tenant constraints, role enforcement, and frontend shop selection as one coordinated release.\n\n## 10. Current production caution

The owner reports `upgrade-08.sql` through `upgrade-14.sql` were executed successfully. This is a user-reported status, not an independent database verification. Before any further tenant migration, create and test against a separate Supabase test project, verify the live schema and row counts, and take a restorable production backup.


## 11. Next development stage\n\nThe next safe coding stage is a read-only tenant readiness audit and a test-project migration package. Do not yet add customer sign-up, tenant switching, tenant-scoped write RPCs, or new shop creation in the live app. Existing business RPCs and direct table access remain owner-scoped.\n