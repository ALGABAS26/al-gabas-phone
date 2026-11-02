# Security Review — Next-Stage Implementation Specification

**Authority:** owner-supplied specification from the prior project discussion.  
**Status:** design/review and branch implementation only. No production database changes are authorized.  
**Repository:** `ALGABAS26/al-gabas-phone`.  
**Working branch:** `erp-security-fixes-draft`.  
**Production baseline:** `main`.

## 1. Non-negotiable scope boundary

- ERP files only.
- Never alter `public.products`, its RLS policies, grants, storefront code, or product-admin workflow during ERP remediation.
- Do not execute SQL against the live Supabase project in this stage.
- Do not onboard additional shops until the complete tenant-isolation release passes.
- Do not merge to `main` or deploy without explicit owner approval.
- Keep the current single-shop experience operational while replacements are built and tested.

## 2. Confirmed production observations supplied by the owner

These are owner-supplied observations, not independently re-queried in this coding stage:

- RLS is enabled on all inspected ERP tables; FORCE RLS is false.
- Operational policies currently use `owner_id = auth.uid()` for authenticated users.
- No matching anon ERP policies appeared in the supplied policy inventory.
- Table ACL output showed anon and authenticated with broad privileges on 30 public tables, including TRUNCATE, TRIGGER, REFERENCES, and MAINTAIN. This is an ACL concern; it does not by itself prove anonymous requests bypass RLS.
- Default ACLs for objects created by both `postgres` and `supabase_admin` grant broad privileges to anon and authenticated for tables, functions, and sequences.
- Schema public grants USAGE but not CREATE to anon and authenticated.
- `product_admins` and `test_connection` have RLS enabled but no policies appeared in the supplied policy query. Leave their access untouched until their purpose is verified.
- `shop_id` columns and shop metadata exist, but the current app and operational authorization remain owner-scoped.

## 3. Application compatibility inventory

The browser app uses the Supabase publishable/anon key and Supabase Auth.

Direct writes currently present in `accounting/app.js`:

1. `erp_products` plus optional `erp_product_units` (two separate requests; not atomic today).
2. `erp_fawry_transactions`.
3. `erp_cash_accounts` opening-balance upsert.
4. `erp_cash_movements` manual movement.
5. `erp_parties`.
6. `erp_party_transactions`.
7. `erp_maintenance_orders`.
8. `erp_shop_settings` upsert.

Direct reads remain across inventory, IMEI, Fawry, cash, invoices, parties, purchases, maintenance, expenses, returns, stock counts, settings, and reports. Generic `fetchAll(table)` is used for pagination and data collection. Export and backup paths require future shop scoping.

Existing RPC workflows include sale, purchase, expense, Fawry daily close, cash transfer, stock count posting, return posting, cash account initialization, and current shop profile.

## 4. Package A — privilege hardening (single-shop compatibility)

Prepare, but do not execute, a narrowly scoped migration that:

- removes unnecessary anon table privileges from ERP-only tables;
- removes client-role TRUNCATE, TRIGGER, REFERENCES, and MAINTAIN where not required;
- preserves the exact authenticated SELECT/INSERT/UPDATE/DELETE access still needed by the current app until direct writes have RPC replacements;
- tightens default privileges separately for each object-creating role (`postgres`, `supabase_admin`) and object type (tables, functions, sequences);
- grants only the minimum sequence access needed by actual identity-backed inserts;
- leaves `public.products`, `product_admins`, and storefront permissions untouched;
- audits function EXECUTE separately; trigger functions and client RPCs are different categories.

Existing-object ACLs and future-object default ACLs are separate. A default-privilege change does not repair existing objects.

## 5. Package B — migrate direct writes to server-validated RPCs

Implement and test one workflow at a time:

1. create product plus optional IMEI unit atomically;
2. create Fawry transaction;
3. upsert cash opening balances;
4. create manual cash movement;
5. create party;
6. create party ledger transaction;
7. create maintenance order;
8. upsert shop settings.

Each RPC must derive the authenticated user from `auth.uid()`, validate ownership/authorization server-side, validate inputs and related IDs, and use a fixed safe `search_path` if SECURITY DEFINER is necessary. Prefer SECURITY INVOKER where it meets the design. Never trust a client-supplied owner ID.

During this migration, do not revoke the existing authenticated table DML needed by workflows that have not yet been replaced. A workflow is complete only after its app caller uses the RPC and staging tests pass.

## 6. Package C — tenant authorization (coordinated release only)

- Make `shop_id` NOT NULL only after verified backfill and orphan checks.
- Define one membership/role authorization helper with explicit active-membership checks.
- Add role-specific permissions; viewer must not post transactions.
- Make every business RPC validate requested shop and required role before touching rows.
- Add tenant-safe unique constraints and composite foreign keys to prevent cross-shop references.
- Update direct reads, joins, nested relations, pagination, reports, CSV/JSON export, backup, and IMEI workflows to scope by active shop.
- Add storage path and signed URL isolation if storage is used.
- Keep billing/subscription writes server-controlled.
- Do not replace owner policies table-by-table in production. Deploy the complete coordinated migration only after test-project validation.

## 7. Required tests before production release

Use two synthetic shops and distinct users/roles. Test:

- cross-shop SELECT/INSERT/UPDATE/DELETE through REST;
- forged shop IDs and wrong-role RPC calls;
- cross-shop product, party, invoice, line-item, cash-account, and IMEI references;
- sale, purchase, return, stock count, cash transfer, and Fawry workflows;
- membership revocation and suspended/expired subscription rules;
- pagination, reports, CSV/JSON exports, backups, and storage access;
- current single-shop regression tests for every existing workflow.

All cross-shop and unauthorized attempts must fail at the database boundary, not merely in UI code.

## 8. Rollout and rollback

- Create a verified restorable backup and test restore.
- Rehearse migrations on a separate Supabase test project with synthetic data.
- Record pre-migration row counts, constraints, policies, ACLs, function definitions, and app commit SHA.
- Deploy app and database changes as a coordinated version.
- Run smoke tests immediately after deployment.
- Keep a tested rollback plan. Never rollback by deleting user business data.

## 9. First implementation slice in this branch

The first workflow is `erp_products` + optional `erp_product_units`.

- New migration: `upgrade-15.sql`.
- RPC: `erp_create_product_with_optional_imei(...)`.
- Uses SECURITY INVOKER and fixed `search_path = pg_catalog, public`.
- Derives `owner_id` from `auth.uid()`; no owner ID argument exists.
- Validates required product fields, condition, nonnegative amounts/quantity, IMEI format, Luhn check, same-row duplicate IMEI, and quantity=1 for a tracked unit.
- Product and optional unit are inserted in one database transaction.
- Existing authenticated direct table privileges are intentionally preserved during this first migration.
- Adds a staging-only rollback-based regression script for normal product, IMEI product, invalid Luhn, duplicate IMEI, and atomic rollback.
- The app change is kept on the working branch and must be deployed together with the migration after staging validation.

## 10. Release state

This branch work is not production authorization. No live SQL is run by this specification. No shop onboarding is permitted. No storefront object or `public.products` permission is in scope.

## 11. Second implementation slice — Fawry transaction creation

- New migration: `upgrade-16.sql`.
- RPC: `erp_create_fawry_transaction(p_type, p_amount, p_commission, p_fee, p_reference, p_status, p_notes)`.
- The browser caller now invokes this RPC instead of directly inserting into `erp_fawry_transactions`.
- The RPC uses `SECURITY INVOKER`, fixed `search_path = pg_catalog, public`, and derives the owner only from `auth.uid()`.
- Validates the transaction type and status against the existing table check constraints; requires a positive finite amount and nonnegative finite commission/fee; rejects NULL required values; trims blank reference/notes to NULL.
- Preserves the existing table schema, owner RLS policy, and authenticated table DML needed by other workflows.
- Does not alter Fawry daily closing, its stable closing-row source ID, cash movement triggers, or cash account behavior.
- Adds a rollback-based staging regression script for valid insertion, owner binding, defaults, invalid type/status/amount/commission/fee, NULL amount, and missing authentication.
- Migration and test are prepared only. Neither has been executed; no staging or production runtime test has passed yet.
- Required deployment pairing: apply `upgrade-16.sql` in the separate staging project before deploying the matching `accounting/app.js` version there.
