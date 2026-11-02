# AL GABAS ERP — Multi-Shop Implementation and Release Package

**Status:** design and audit package only; not deployed.  
**Target branch:** `erp-security-fixes-draft`  
**Production branch:** `main`

## 1. Objective

Prepare the existing AL GABAS ERP to host multiple independent shops (tenants), each with its own owner, employees, records, permissions, and subscription, without breaking the current shop.

This is not achieved by adding a shop selector alone. The database must enforce tenant boundaries for every table, RPC, foreign key, export, and background operation.

## 2. Safety boundary

- Work only on `erp-security-fixes-draft` until the owner explicitly approves a reviewed release.
- Do not merge to `main`, deploy the app, or run SQL on the current Supabase project without explicit approval.
- Do not modify the storefront, `public.products`, its policies, or its grants.
- Preserve the current single-shop workflow while building and testing the tenant-aware replacement in a separate Supabase test project.
- Do not invite another shop or share the existing login until the multi-tenant release gates pass.
- Keep `owner_id` during the transition as a legacy/creator field. Do not treat it as the permanent tenant boundary.
- All migrations must be additive first. No destructive drop/rename or premature NOT NULL conversion.

## 3. Confirmed baseline from repository source

The current repository has:
- `upgrade-13.sql`: creates `erp_shops`, `erp_shop_memberships`, `erp_shop_subscriptions`, and `erp_shop_audit_log`; adds nullable `shop_id` to the listed ERP business tables; backfills one initial shop per existing owner; aborts if owner-owned rows remain unassigned.
- `upgrade-14.sql`: adds `erp_my_shop_profile()` and controlled SELECT policies for the caller's own shop metadata.
- Current business-table RLS and business RPCs remain owner-based.
- The current app reads one profile through `erp_my_shop_profile()`, displays the shop/role/subscription chip, and does not select an active shop or pass shop context to business operations.
- The app still has direct REST table writes in eight workflows (see `ERP-SECURITY-REMEDIATION-PLAN.md`); these must be migrated before direct table DML privileges can be safely removed.
- Existing accounting RPCs (sales, purchases, returns, expenses, cash transfers, stock counts, Fawry close, cash initialization) also require tenant-aware authorization and role checks.
- The current shop-profile function returns only one membership row (`LIMIT 1`); a multi-shop user needs a secure list-of-shops function and a validated active-shop selection.

This baseline is derived from repository source, not a fresh query against the live Supabase project.

## 4. Target architecture

### 4.1 Tenant identity and membership

- `erp_shops.id` is the tenant identifier.
- `erp_shop_memberships` maps Auth users to shops and roles.
- One user may belong to multiple shops and switch between them.
- Each shop has exactly one active owner at a time (ownership transfer is a separate owner-only audited operation).
- Membership status and shop status are checked server-side on every protected operation.
- An invited membership is not active until the invitation is accepted and the invited Auth identity is verified.
- Never create shared logins for multiple shops.

### 4.2 Active shop context

- Add a server function such as `erp_my_shops()` returning every active membership for `auth.uid()`, with shop ID/name/status/role/subscription summary.
- The UI shop switcher selects a shop ID, but the database revalidates the caller's active membership on every read/write.
- Client-side local storage may remember the last selected shop for convenience only; it is never authorization evidence.
- On switching shops, clear all in-memory rows, cached reports, selected invoice/product/party IDs, and pending form state before loading the new shop.
- If membership is revoked or shop is suspended, subsequent requests must fail at the database boundary even if the UI still holds a stale shop ID.
- The existing single-row `erp_my_shop_profile()` can remain for backward compatibility during migration, but must not be treated as a multi-shop selector API.

### 4.3 Tenant-scoped data

Every ERP business row must have a valid non-null `shop_id` after the controlled cutover. The current upgrade-13 list is the starting inventory, not proof of completeness. Reconcile it against every table in schema.sql and upgrades 02–14, including child, ledger, mapping, audit, and future tables.

Required constraints:
- `UNIQUE(shop_id,id)` parent keys where composite references are required.
- Composite FKs such as `(shop_id, product_id)`, `(shop_id, invoice_id)`, and `(shop_id, product_unit_id)` for all supported parent-child relationships.
- Same-shop guards for relationships not expressible as composite FKs.
- Unique business identifiers scoped to shop where appropriate (e.g. barcode, invoice number, maintenance ticket number, shop slug).
- IMEI uniqueness remains per shop or per owner according to the confirmed business/legal rule; do not silently change the existing owner-scoped uniqueness semantics.

Never use an unverified global UUID reference as proof that parent and child belong to the same shop.

### 4.4 RLS and database permissions

- RLS must be enabled on every tenant table; use FORCE ROW LEVEL SECURITY where compatible with the migration and function ownership model.
- SELECT policies must require an active membership in the row's `shop_id` and the appropriate role/read scope.
- Browser roles receive no direct INSERT/UPDATE/DELETE on ERP business tables after every write path has a tested RPC replacement.
- Each write RPC validates `auth.uid()`, `p_shop_id`, membership status, role, shop status, and subscription state before touching business rows.
- Because a SECURITY INVOKER RPC cannot bypass revoked table DML grants, choose one coherent model: (a) narrowly designed SECURITY DEFINER write RPCs with strict authorization and exact EXECUTE grants, or (b) retain table DML and enforce equally strict RLS plus business invariants. Do not mix assumptions. For this project, the intended target is server-validated SECURITY DEFINER write RPCs after a complete security review.
- SECURITY DEFINER functions require fixed safe `search_path`, explicit qualification of objects, no unsafe dynamic SQL, strict input validation, and exact signature grants. PUBLIC/anon EXECUTE must be reviewed and revoked narrowly.
- Trigger functions and helper functions must be audited separately from user-callable RPCs.

### 4.5 Roles and subscriptions

Use the target matrix in `ERP-MULTISHOP-PERMISSION-MATRIX.md`. Roles are enforced in the database, not only by hiding UI controls.

Subscription rules must be explicit before commercial onboarding:
- Define plan entitlements and limits (users, products, locations/branches, storage, support).
- Define trial, active, past-due, grace, suspended, cancelled, and expired behavior.
- A restricted/expired shop should normally retain owner read/export access for a defined recovery period while prohibited writes are blocked.
- Do not store card numbers or payment authentication secrets in ERP tables.
- Subscription status and plan limits are enforced by server-side RPCs, never local JavaScript.

## 5. Work packages and order

### WP0 — Baseline and backup rehearsal
1. Freeze production schema changes.
2. Create a separate Supabase test project.
3. Capture the current schema, migration history, extensions, RLS policies, grants/default privileges, function signatures/definitions, indexes, triggers, and representative synthetic data.
4. Take a restorable backup of the production project using the available Supabase backup/PITR facility and a separate logical export. Export Storage objects separately if used.
5. Restore the backup into a non-production project and prove that authentication/configuration can be reconnected without exposing production secrets.
6. Record baseline row counts and critical accounting balances.

### WP1 — Read-only inventory and legacy backfill verification
- Run the read-only tenant/relationship/ACL diagnostics against the intended database and save every result set.
- Confirm all ERP tables are in scope; identify any tables omitted from upgrade 13.
- Check every `shop_id IS NULL`, orphan relation, cross-owner relation, cross-shop relation, duplicate tenant key, and conflicting unique constraint.
- Verify that the current owner maps to exactly the intended initial shop and that all related invoice, payment, cash, return, stock, and IMEI rows share that shop.
- Do not repair legacy rows automatically. Produce a reviewed repair list first.

### WP2 — Permission matrix and ACL design
- Approve `ERP-MULTISHOP-PERMISSION-MATRIX.md` against actual staff workflows.
- Inventory current and default ACLs for all ERP tables, sequences, schemas, and exact function signatures.
- Separate table privileges, RLS policies, RPC EXECUTE grants, SECURITY DEFINER ownership, and trigger/helper execution.
- Prepare one standalone ACL migration only after the live/test-project ACL snapshot and all replacement RPCs are known.
- Do not use broad wildcard revokes or alter `public.products`.

### WP3 — Relationship and tenant constraints
- Add shop-scoped unique keys and composite foreign keys only after diagnostics prove they can be created.
- Add missing sale-unit mapping guard and fix exact current-sale IMEI correlation.
- Preserve purchase-unit and return IMEI guards.
- Preserve cash balance trigger, transfer lock order, invoice atomicity, and Fawry source identity/idempotency.
- Add concurrency tests for returns, cash outflows/transfers, Fawry close, and serial-unit selection.

### WP4 — Shop-aware RPCs
Update existing business RPCs rather than layering a parallel, inconsistent authorization model:
- sales and purchase posting;
- expense posting;
- cash transfer and cash account initialization;
- Fawry daily close and Fawry transaction intake;
- return posting and stock-count posting;
- all eight direct-write workflows listed in `ERP-SECURITY-REMEDIATION-PLAN.md`.

Every RPC must validate tenant and role before locking or mutating rows. Preserve transaction atomicity and existing ledger/cash/inventory effects. Never trust browser-supplied `owner_id`.

### WP5 — Frontend tenant context
- Add a shop list/switcher using the server-returned memberships.
- Pass the selected shop ID to every shop-aware RPC; do not filter only in JavaScript.
- Scope every direct SELECT query by the selected shop during transition, while relying on RLS as the real boundary.
- Clear caches and selected records on shop switch.
- Add role-aware navigation and disabled actions for usability, while the database remains authoritative.
- Add membership/invitation administration, owner transfer safeguards, shop profile/settings, and subscription status views.
- Ensure every success refresh reloads data for the selected shop only.

### WP6 — Automated isolation and accounting regression
Follow `ERP-MULTISHOP-REGRESSION-TEST-PLAN.md`. At minimum, test two shops and all seven roles, including forged IDs, direct REST requests, RPC calls, foreign references, concurrent financial operations, membership revocation, and exports.

### WP7 — Cutover and rollback
- Restore-tested backup exists.
- All migrations pass on the test project in documented order.
- Two-shop isolation and all accounting regression tests pass.
- App version and database migration version are compatible.
- Production cutover is performed in a maintenance window with a verified rollback plan.
- Keep old `owner_id` and legacy policies until the new path is verified; remove them only in a separately approved final migration.
- Owner gives explicit approval before production SQL, merge to `main`, or deployment.

## 6. Backup and restore checklist

### Before any production change
- Record Supabase project reference and current migration/version state (do not publish secrets).
- Create/confirm a provider backup or point-in-time recovery point appropriate to the project's plan.
- Create a separate logical backup of schema and data using the currently supported Supabase/Postgres tooling.
- Export Storage objects and metadata separately if ERP uploads exist.
- Save exact RLS policies, grants, default privileges, function definitions, triggers, indexes, extensions, and sequence state.
- Record row counts and financial control totals: cash account balances, invoice totals, party balances, inventory quantities, Fawry closes, returns, and IMEI unit counts.
- Store backup files securely outside the repository; never commit database dumps, credentials, service-role keys, or customer data.

### Restore rehearsal
- Restore to a separate non-production project.
- Verify table counts, foreign keys, RLS, functions, auth connectivity, storage objects, and accounting control totals.
- Run the regression suite on the restored copy.
- Document the exact restore owner, duration, and recovery point.

### Rollback rule
Do not rely on a hand-written reverse migration after tenant data or memberships have been created. Prefer restoring the verified pre-cutover snapshot into a controlled recovery project and reconciling writes made after the snapshot. Keep the previous app build available. Do not delete legacy identifiers during the first tenant release.

## 7. Explicit blockers before writing the executable ACL migration

The standalone permission-remediation SQL is intentionally not generated yet. It must be based on:
1. The complete live/test database ACL output for every ERP table, sequence, schema, and exact function signature.
2. Current default privileges for the actual object-creating role(s).
3. The final set of tenant-aware RPCs and their SECURITY INVOKER/DEFINER decisions.
4. The final role matrix and approved read scopes.
5. A staging test proving that required RPCs still work after browser table DML is revoked.

A generic `REVOKE ALL ON ALL TABLES` or `REVOKE EXECUTE ON ALL FUNCTIONS` could break triggers, RPCs, and current screens. Therefore the ACL file will be generated as a separate, narrowly scoped migration after the above evidence is reviewed. The current SQL companion is a read-only ACL inventory, not a permission-changing migration.

## 8. Release status

- This package is documentation and read-only diagnostics only.
- No SQL has been executed by this package.
- No live Supabase permissions, policies, rows, or functions have been changed.
- No production app files, storefront files, or `public.products` have been changed.
- No changes to `main`; all package files belong on `erp-security-fixes-draft`.
