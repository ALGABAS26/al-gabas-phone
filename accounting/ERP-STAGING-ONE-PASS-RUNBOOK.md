# AL GABAS ERP — One-pass staging verification runbook

**Status:** execution instructions only. No staging or production database has been accessed by this document.  
**Target:** a restored, isolated Supabase staging project with synthetic data.  
**Hard boundary:** never run this sequence against production. Do not merge this branch or deploy it as part of this runbook.

## 1. Scope and safety

- Repository: `ALGABAS26/al-gabas-phone`
- Branch: `erp-security-fixes-draft`
- ERP files only, under `accounting/`.
- Do not alter `main`, storefront files, `public.products`, its policies, or grants.
- Do not execute the read-only audits against production.
- Do not execute a broad ACL revoke, default-privilege change, RLS rewrite, or composite-FK migration.
- Use only synthetic users, shops, products, IMEIs, parties, invoices, and cash balances in staging.
- Keep service-role keys and database passwords out of GitHub, SQL output, screenshots, and chat.

## 2. Before running SQL

1. Create a separate Supabase staging project (not merely a second schema in production).
2. Restore a recent production backup into staging, or reproduce the schema/migration history without copying personal or payment data. Keep staging credentials separate.
3. Confirm the PostgreSQL major version and installed extensions.
4. Capture the staging schema, migration history, indexes, triggers, functions, RLS policies, relation/function/sequence ACLs, and default ACLs.
5. Record baseline control totals: product quantities, IMEI-unit counts, invoice totals, cash-account balances, party balances, Fawry closes, and return totals.
6. Create isolated synthetic auth users and fixture records. Use IDs reserved for testing; never reuse real customer records.
7. Confirm a restore point exists for staging itself.

If any prerequisite is missing, stop before applying migrations.

## 3. Apply the draft migrations in order

Apply only in staging, after confirming the base schema and upgrades 01–14 match this branch:

1. `accounting/upgrade-15.sql` through `upgrade-22.sql` in numeric order.
2. `accounting/upgrade-23.sql`
3. `accounting/upgrade-24.sql`
4. `accounting/upgrade-25.sql`
5. `accounting/upgrade-26.sql`
6. `accounting/upgrade-27.sql`

Use one migration at a time. Stop immediately on the first SQL error; do not skip ahead or continue with a partially applied migration. Record the exact file, database version, error, and migration transaction state. Review whether the file wraps changes in a transaction before deciding how to recover.

These migrations include SECURITY INVOKER RPC replacements, exact EXECUTE grants/revokes, IMEI mapping, return serialization, Fawry chronology, input validation, and shop-profile subscription disclosure hardening. They are drafts until this staging sequence succeeds.

## 4. Run the matching rollback regression scripts

Run each test only after its matching migration has succeeded:

- `accounting/tests/upgrade-15-product-rpc-regression.sql`
- `accounting/tests/upgrade-16-fawry-rpc-regression.sql`
- `accounting/tests/upgrade-17-cash-opening-rpc-regression.sql`
- `accounting/tests/upgrade-18-manual-cash-movement-rpc-regression.sql`
- `accounting/tests/upgrade-19-party-rpc-regression.sql`
- `accounting/tests/upgrade-20-party-transaction-rpc-regression.sql`
- `accounting/tests/upgrade-21-maintenance-rpc-regression.sql`
- `accounting/tests/upgrade-22-settings-rpc-regression.sql`
- `accounting/tests/upgrade-23-sale-imei-regression.sql`
- `accounting/tests/upgrade-24-return-regression.sql`
- `accounting/tests/upgrade-25-fawry-chronology-regression.sql`
- `accounting/tests/upgrade-26-rpc-validation-regression.sql`
- `accounting/tests/upgrade-27-shop-profile-privilege-regression.sql`

Before each test, replace only the documented synthetic fixture IDs and confirm the test's preconditions. Never run a test with an unknown ID or a real user's auth UUID. A `ROLLBACK` in a test does not make it safe for production; these tests are staging-only.

## 5. Additional tests that require independent sessions

The single-session regression scripts do not prove race safety. Run these with two independent authenticated staging sessions and record both outcomes:

- Two concurrent returns against the same original invoice line; only the valid cumulative quantity may commit.
- Two concurrent Fawry close writes for the same owner/date; no duplicate top-up movement or inconsistent predecessor/successor chain.
- Two concurrent cash outflows/transfers from one account near its available balance; no overdraw.
- Two concurrent IMEI inserts with the same IMEI in either slot; duplicate prevention must be demonstrated at the database boundary.
- Concurrent sales selecting the same tracked unit; at most one sale may successfully claim it.

Also verify purchase positive paths: normal product, IMEI-tracked product, weighted-average cost, supplier balance, invoice totals, payment rows, cash movements, and exact purchase-unit mapping. Verify sale/return positive paths and cash/party ledger effects.

## 6. Run read-only evidence audits

After the migration and regression pass, run these in staging and export every result set:

1. `accounting/ERP-RELATIONSHIP-READONLY-AUDIT.sql` — broad relationship, index, RLS, trigger, IMEI, and function evidence.
2. `accounting/ERP-OWNER-FK-PREFLIGHT-AUDIT.sql` — flags ERP foreign keys that omit owner_id and emits manual orphan/cross-owner SELECT checks. It does not execute generated statements.
3. `accounting/ERP-ACL-EXECUTION-DEPENDENCY-AUDIT.sql` — exact table, sequence, function, trigger, schema, membership, and default-ACL evidence.
4. `accounting/ERP-MULTISHOP-ACL-REVIEW-DRAFT.sql` — supplemental read-only ACL inventory.

Keep raw outputs intact. Redact secrets and personal data before sharing. For the owner-FK audit, run every generated SELECT statement individually and preserve its result. Check candidate composite parent keys for uniqueness and inspect nullable relationships before proposing constraints.

## 7. ACL decision gate — no automatic revoke

Do not prepare or apply a production ACL migration merely because an audit shows broad grants.

First create a dependency matrix containing:
- exact object and function signatures;
- current and effective grants (including PUBLIC and inherited role membership);
- function owner, SECURITY INVOKER/DEFINER, search_path, and EXECUTE grantees;
- client RPC versus trigger function versus internal helper classification;
- direct REST/table DML dependencies still used by the app;
- sequences used by insert paths and their required privileges;
- default ACL creator roles and object types;
- regression proving every intended workflow still works under the proposed permission model.

Only after this matrix is reviewed should a narrowly scoped ACL migration be designed. Preserve required authenticated access while SECURITY INVOKER RPCs depend on it. Never revoke all functions or all table privileges indiscriminately. Never touch `public.products`.

## 8. Owner-aware FK decision gate

For each candidate relationship:
1. Confirm both child and parent tables are truly shop/owner scoped.
2. Run orphan and cross-owner checks.
3. Check whether the parent already has a unique key on the exact referenced columns.
4. Inspect nullable FK semantics and existing trigger/application behavior.
5. Check duplicates and write-path compatibility.
6. Add a composite key/FK only in a separate reviewed migration with positive and negative regression coverage.

No FK migration is included in this branch until staging evidence supports the exact constraint list.

## 9. Multi-Shop is a separate release, not enabled by this work

The current app and RPCs are still owner-scoped. A `shop_id` column alone does not provide tenant isolation. Before onboarding another shop, complete the permission matrix, membership helper, shop-aware authorization in every RPC, tenant-safe constraints, reads/exports/storage scoping, server-side subscription enforcement, two-shop/seven-role isolation tests, backup restore rehearsal, and explicit release review.

Do not use this staging verification as permission to onboard other shops.

## 10. Evidence packet to return for final review

Provide:
- PostgreSQL version and migration history;
- success/error result for each migration and regression script;
- two-session concurrency results;
- all four audit outputs, including generated orphan/cross-owner query results;
- baseline and post-test accounting control totals;
- any SQLSTATE, error text, and failing test name;
- confirmation that staging is isolated and contains synthetic data only.

Do not send secrets, access tokens, service-role keys, customer data, or full raw IMEI values.

## 11. Current known status

- Draft migrations and regression files are committed only to `erp-security-fixes-draft`.
- Source-to-source comparison of the purchase RPC found its original successful-path accounting effects preserved in upgrade 26; runtime equivalence remains unproven.
- ERP RPC search_path settings in upgrades 15–26 now explicitly place `pg_temp` last.
- The owner-FK preflight audit is read-only and does not execute generated checks.
- No PostgreSQL parser/runtime test, staging migration, staging regression, or concurrency test has been run by this assistant.
- No production SQL, ACL changes, merge, or deployment has occurred.
