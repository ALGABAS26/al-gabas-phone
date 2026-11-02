# Production security remediation — AL GABAS STORE ERP

Status: **audit only; no production database changes have been made.**

## Verified application access pattern

The current browser app uses the Supabase publishable/anon key and Supabase Auth. It performs direct PostgREST table operations as well as RPC calls.

Direct table operations found in `accounting/app.js` include:
- `erp_products`: INSERT, SELECT
- `erp_fawry_transactions`: INSERT, SELECT
- `erp_cash_accounts`: UPSERT, SELECT
- `erp_cash_movements`: INSERT, SELECT
- `erp_parties`: INSERT, SELECT
- `erp_party_transactions`: INSERT, SELECT
- `erp_maintenance_orders`: INSERT, SELECT
- `erp_shop_settings`: UPSERT, SELECT
- Additional direct SELECTs across invoices, invoice items, expenses, returns, stock counts, and related tables.

Atomic business operations already use RPCs in several places:
- `erp_create_sale`
- `erp_create_purchase`
- `erp_record_expense`
- `erp_save_fawry_daily_close`
- `erp_transfer_cash`
- `erp_post_stock_count`
- `erp_post_return`

## Database audit findings reported by the owner

- RLS is enabled on all 28 ERP tables; FORCE RLS is false.
- Operational RLS policies are primarily owner-scoped using `owner_id = auth.uid()`.
- `shop_id` exists on ERP tables but current business policies and reviewed RPCs do not consistently enforce it.
- Information-schema grants show `anon` and `authenticated` with SELECT/INSERT/UPDATE/DELETE/TRUNCATE on all 28 ERP tables.
- Most business RPCs have EXECUTE granted to PUBLIC/anon/authenticated in the inspected ACL output.
- `erp_my_shop_profile()` is SECURITY DEFINER and executable by authenticated/service_role, not anon/PUBLIC in the inspected ACL output.

## Critical compatibility warning

Do **not** revoke all INSERT/UPDATE/DELETE from `authenticated` in one step. The current frontend depends on direct table writes listed above. A blanket revoke would break product creation, Fawry transaction entry, opening cash balances, manual cash movements, parties, maintenance orders, and shop settings.

Likewise, do not change production RLS from owner_id to shop_id until every frontend query, direct write, RPC, trigger, export, backup, and foreign-key relationship has been migrated and tested as one coordinated release.

## Safe remediation sequence

1. Preserve the current production behavior; take and verify a restorable backup before any database permission change.
2. Inspect exact table ACLs and default privileges, distinguishing explicit grants from grants inherited through PUBLIC. The information-schema result alone is not enough to decide which grant statement to issue.
3. Prepare a least-privilege matrix for each table and each role. Separate client-required SELECT from direct writes that should become RPCs.
4. Move each direct write listed above into a validated RPC, one workflow at a time, and test the current single-shop app after each code change.
5. Prepare a reviewed permission migration that removes unnecessary anon access and TRUNCATE privileges while preserving required authenticated behavior until replacement RPCs are deployed. Validate the exact Supabase/PostgREST role behavior before production execution.
6. Migrate all business rows and operations to shop_id + active membership + role checks. Add tenant-safe foreign keys/constraints.
7. Test two synthetic shops, direct REST access, RPCs, exports/backups, IMEI, returns, cash transfers, membership revocation, and subscription restrictions.
8. Deploy only as a coordinated, backed-up release with a rollback plan and explicit owner approval.

## Non-negotiable boundaries

- Never modify `public.products` or the public storefront as part of ERP security work.
- Never execute unreviewed GRANT/REVOKE or RLS changes in production.
- Do not onboard another shop or share the current login until tenant isolation tests pass.
