# AL GABAS ERP — One-pass staging review and release gate

**Status: prepared for staging; not executed.**  
**Scope:** ERP only, repository `ALGABAS26/al-gabas-phone`, branch `erp-security-fixes-draft`.  
**Hard boundary:** do not run any of these scripts against production. Do not change `main`, storefront files, `public.products`, its grants/RLS/policies, or product-admin behavior.

## What is prepared

- Draft migrations `upgrade-15.sql` through `upgrade-27.sql` and matching rollback regression scripts under `accounting/tests/`.
- Read-only ACL/execution dependency inventory: `ERP-ACL-EXECUTION-DEPENDENCY-AUDIT.sql`.
- Read-only relationship/IMEI audit: `ERP-RELATIONSHIP-READONLY-AUDIT.sql`.
- Read-only owner-aware FK preflight: `ERP-OWNER-FK-PREFLIGHT-AUDIT.sql`.
- Review notes: `ERP-FIFTH-PASS-REVIEW.md`.

No migration or test in this package has been run against PostgreSQL in this work session. Static review is not a substitute for PostgreSQL parsing, staging behavior, or real JWT testing.

## One-pass staging sequence

### 0. Establish an isolated staging baseline

1. Use a separate Supabase staging project, not production.
2. Restore a recent schema-and-data snapshot with sensitive customer data removed or anonymized. Do not share service-role keys or database passwords in chat.
3. Determine exactly which ERP migrations are already applied in staging. Do not blindly replay migrations 01–14 or any migration already applied.
4. Confirm the staged schema corresponds to the intended production baseline and that the migration owner/creator roles match the ACL audit target.

### 1. Capture pre-change evidence before applying upgrades 15–27

Run these files in the staging SQL editor, saving every result set:

1. `ERP-ACL-EXECUTION-DEPENDENCY-AUDIT.sql`
2. `ERP-RELATIONSHIP-READONLY-AUDIT.sql`
3. `ERP-OWNER-FK-PREFLIGHT-AUDIT.sql`

All three are SELECT/catalog-only audits. The owner-FK audit emits SQL text for orphan and cross-owner checks; copy and run those generated SELECT statements individually. It does not execute generated SQL.

For every candidate owner-aware FK, record:
- child and parent relation and exact FK column mapping;
- whether `owner_id` is absent from the FK;
- orphan row count and cross-owner row count;
- whether the proposed parent key is backed by a valid unique/primary key;
- nullable/optional relationship semantics and any app/RPC dependency.

Do not create composite FKs or unique indexes while any orphan, cross-owner, duplicate-key, or semantic question remains unresolved.

### 2. Apply draft upgrades in staging only

After confirming the staged baseline, apply only the missing draft upgrades in numerical order, one at a time:

`upgrade-15.sql` → `upgrade-16.sql` → ... → `upgrade-27.sql`.

Stop at the first SQL error. Record the exact migration, error text, and PostgreSQL version. Do not continue past a failed migration and do not attempt a production repair from this draft.

### 3. Run rollback regression tests

Run the matching scripts in `accounting/tests/` in numerical order, each in the isolated staging project. Replace only the clearly marked synthetic fixture IDs and ensure the synthetic auth user/membership setup meets each test's documented preconditions.

In addition to the rollback scripts, complete the two-session concurrency checks called out in the relevant test files:
- return over-quantity race (upgrade 24);
- Fawry same-day/historical close race (upgrade 25);
- any transfer/account-lock race coverage required by the cash-movement implementation.

Complete positive-path purchase assertions from upgrade 26:
- ordinary purchase: stock, weighted-average cost, invoice totals;
- partial payment: supplier ledger, payment row, linked cash outflow;
- IMEI purchase: valid units and exact purchase-line mapping;
- rejection paths: malformed/duplicate IMEI and mismatched unit count leave no partial invoice/stock/cash changes.

For upgrade 27, test with authenticated JWT claims for viewer and admin roles. Confirm the viewer receives NULL subscription fields and the admin receives the expected values. Also confirm the client app does not depend on subscription metadata for non-admin roles.

### 4. Capture post-change evidence

Rerun all three read-only audits after the draft upgrades and compare before/after outputs. Specifically confirm:
- expected RPC EXECUTE grants only for exact signatures;
- no unintended authenticated/anon access changes;
- trigger functions remain callable through trigger execution and are not broken by blanket revokes;
- required sequence privileges remain available to intended invoker workflows;
- default ACLs are understood separately for each creator role/object type;
- no new relationship, RLS, or IMEI anomalies were introduced.

### 5. ACL and tenant-isolation decisions

**No ACL revoke migration is included or authorized by this package.** Build one only after the exact pre/post staging evidence is reviewed, the function inventory is classified as browser RPC vs trigger vs internal helper, and all authenticated direct-write workflows are migrated and tested. Preserve the authenticated DML currently required by SECURITY INVOKER workflows until the dependency review proves it is safe to remove.

**No owner-aware composite-FK migration is included.** Build one only for individually approved relationships after data checks, parent uniqueness checks, and application compatibility review.

**Multi-Shop remains disabled.** The presence of `shop_id` columns does not establish tenant isolation. Do not onboard other shops until membership/role authorization, shop-scoped RPCs, tenant-safe constraints, reads/exports/storage, and server-controlled billing all pass a separate end-to-end release gate.

## Evidence required before release review

Attach/export:
1. staging migration history and PostgreSQL version;
2. complete pre-upgrade ACL, relationship, and owner-FK audit outputs;
3. every generated orphan/cross-owner SELECT result;
4. migration success/error log for upgrades 15–27;
5. every regression result and concurrency-test record;
6. complete post-upgrade audit outputs;
7. browser workflow smoke-test results for sales, purchases, returns, cash, Fawry, expenses, parties, maintenance, settings, and inventory/IMEI.

Until these artifacts are reviewed, the correct status remains **draft / staging not verified / not production secure / not Multi-Shop ready**.
