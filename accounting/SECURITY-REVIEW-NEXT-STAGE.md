# Security review — next-stage implementation specification

Status: **design/review only**. This document does not authorize or perform production database changes.

## Scope boundary
- Repository: `ALGABAS26/al-gabas-phone`, branch `main`.
- ERP files only.
- Never alter `public.products`, its RLS policies, grants, storefront code, or product-admin workflow during ERP remediation.
- Do not execute SQL against the live Supabase project as part of this stage.
- Do not onboard additional shops until the full tenant isolation release passes.

## Confirmed production observations supplied by the owner
1. RLS is enabled on all inspected ERP tables; `FORCE RLS` is false.
2. Operational policies are currently `owner_id = auth.uid()` for `authenticated`.
3. `anon` has no matching ERP RLS policies in the supplied policy inventory.
4. Table ACL output shows `anon` and `authenticated` have broad privileges on 30 public tables, including `TRUNCATE`, `TRIGGER`, `REFERENCES`, and `MAINTAIN`. This is an ACL concern; it does not by itself prove an anonymous request can bypass RLS.
5. Default ACLs for objects created by both `postgres` and `supabase_admin` grant broad privileges to `anon` and `authenticated` for tables, functions, and sequences.
6. Schema `public` grants `USAGE` but not `CREATE` to `anon` and `authenticated`.
7. `product_admins` and `test_connection` have RLS enabled but no policies appeared in the supplied policy query. Their access should remain closed until their actual purpose is verified.
8. `shop_id` columns and shop metadata exist, but current app and operational authorization remain owner-scoped.

## Application compatibility inventory
The browser app uses the Supabase publishable/anon key and Supabase Auth. It currently performs direct writes to:
- `erp_products` and `erp_product_units` (product plus optional IMEI creation)
- `erp_fawry_transactions`
- `erp_cash_accounts` (opening balance upsert)
- `erp_cash_movements` (manual movement)
- `erp_parties`
- `erp_party_transactions`
- `erp_maintenance_orders`
- `erp_shop_settings`

Direct reads are used across inventory, IMEI, Fawry, cash, invoices, parties, purchases, maintenance, expenses, returns, stock counts, settings, and reports. Generic `fetchAll(table)` is used for pagination and data collection. Backup/export paths must be reviewed to ensure they cannot cross shop boundaries in the future.

Existing RPC workflows include sale, purchase, expense, Fawry daily close, cash transfer, stock count posting, return posting, cash account initialization, and current shop profile. Revoke changes must not be applied until each caller and trigger dependency is mapped.

## Remediation work packages

### Package A — privilege hardening (single-shop compatibility)
Prepare, but do not yet execute, a migration that:
- removes unnecessary `anon` table privileges from ERP-only tables;
- removes dangerous/unneeded table privileges such as `TRUNCATE`, `TRIGGER`, `REFERENCES`, and `MAINTAIN` from client roles where not required;
- preserves the exact `authenticated` SELECT/INSERT/UPDATE/DELETE access still needed by the current app until direct writes are migrated;
- tightens default privileges separately for each object-creating role (`postgres` and `supabase_admin`) and object type (tables, functions, sequences);
- grants only the minimum sequence access needed by actual identity-backed inserts;
- leaves `public.products`, `product_admins`, and storefront permissions untouched;
- audits function EXECUTE separately; trigger functions and client RPCs must not be treated as one category.

Do not assume a default-privilege change alters existing objects. Existing ACLs and future-object defaults are separate.

### Package B — migrate direct writes to server-validated RPCs
Implement and test one workflow at a time:
1. create product plus optional IMEI unit atomically;
2. create Fawry transaction;
3. upsert cash opening balances;
4. create manual cash movement;
5. create party;
6. create party ledger transaction;
7. create maintenance order;
8. upsert shop settings.

Each RPC must derive the authenticated user from `auth.uid()`, validate ownership/authorization server-side, validate inputs and related IDs, and use a fixed safe `search_path` if SECURITY DEFINER is necessary. Prefer SECURITY INVOKER where it meets the design. No client-supplied owner ID is trusted.

### Package C — tenant authorization (not a partial release)
- Make `shop_id` NOT NULL only after verified backfill and orphan checks.
- Define a single membership/role authorization helper with explicit active-membership checks.
- Add role-specific permissions; a viewer must not post transactions.
- Make every business RPC validate the requested shop and required role before touching rows.
- Add tenant-safe unique constraints and composite foreign keys to prevent cross-shop references.
- Update all direct reads, joins, nested relations, pagination, reports, CSV/JSON export, backup, and IMEI workflows to scope by active shop.
- Add storage path and signed URL isolation if storage is used.
- Keep billing/subscription writes server-controlled.

Do not replace existing owner policies table-by-table in production. Deploy the full coordinated migration only after test-project validation.

## Required tests before production release
Use two synthetic shops and distinct users/roles. Test:
- cross-shop SELECT/INSERT/UPDATE/DELETE attempts via REST;
- forged shop IDs and wrong-role RPC calls;
- cross-shop product, party, invoice, line-item, cash-account, and IMEI references;
- sale, purchase, return, stock count, cash transfer, and Fawry workflows;
- membership revocation and suspended/expired subscription rules;
- pagination, reports, CSV/JSON exports, backups, and storage access;
- current single-shop regression tests for all existing workflows.

Expected result: all cross-shop and unauthorized attempts fail at the database boundary, not merely in UI code.

## Rollout and rollback
1. Create a verified restorable backup and test restore.
2. Rehearse migrations on a separate Supabase test project with synthetic data.
3. Record pre-migration row counts, constraints, policies, ACLs, function definitions, and app commit SHA.
4. Deploy app and database changes as a coordinated version.
5. Run smoke tests immediately after deployment.
6. Keep a tested rollback plan. Never rollback by deleting user business data.

## Release decision
The current production ERP remains single-owner. It is **not ready for other shops**. The next coding work should begin with RPC replacements and automated tests in the repository, while production remains unchanged.