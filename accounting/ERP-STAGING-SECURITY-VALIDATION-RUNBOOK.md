# ERP Security — Staging Validation Runbook

**Branch:** `erp-security-fixes-draft`  
**Production baseline:** `main`  
**Status:** preparation only. No staging database is currently connected and no SQL in this runbook has been executed.  
**Scope:** `accounting/` ERP only. Never alter `public.products`, storefront files, product-admin policies, or grants.

## 0. Hard safety gates

1. Use a separate Supabase staging project or a disposable branch database, not the production project.
2. Confirm the staging project URL/project reference in the Supabase dashboard before running anything.
3. Take a restorable staging backup/snapshot.
4. Confirm staging has the expected base schema and upgrades 02–14. The owner previously reported those were applied in production; that report is not independent evidence of staging state.
5. Do not run any `upgrade-15.sql` through `upgrade-27.sql` on production.
6. Do not run a REVOKE/GRANT repair, composite-FK migration, RLS rewrite, or Multi-Shop migration as part of the evidence-gathering phase.
7. Never run a script copied from this branch against production. The branch is not a production release.

## 1. Capture read-only baseline evidence first

Run each file separately in staging SQL Editor and save complete result sets with timestamps:

1. `ERP-RELATIONSHIP-READONLY-AUDIT.sql`
2. `ERP-OWNER-FK-PREFLIGHT-AUDIT.sql`
3. `ERP-ACL-EXECUTION-DEPENDENCY-AUDIT.sql`
4. `TENANT-READINESS-AUDIT.sql`

All four are intended as SELECT-only evidence collectors. Review the SQL text before execution in the actual staging editor. Do not execute the generated diagnostic SQL returned as text by the owner-FK audit until its target tables/columns and predicates have been inspected.

### Owner/FK review

For each candidate relationship:
- Confirm child and parent rows are intended to belong to the same owner.
- Review NULL semantics and optional references.
- Run the generated orphan and cross-owner count SELECTs individually.
- Check proposed parent key uniqueness and inspect existing primary/unique constraints.
- Save sample identifiers only in the private staging report; do not copy customer/IMEI values into issue comments.
- Do not create a composite FK until orphan count and cross-owner count are both zero, the parent key is unique, and application insert/update order is compatible.

### ACL review

For each ERP relation and exact function signature:
- Compare raw ACL, effective privilege results, PUBLIC grants, role membership, and object owner.
- Classify each function as browser RPC, trigger function, or internal helper.
- Record SECURITY INVOKER/DEFINER, owner, fixed search_path, effective EXECUTE, and trigger dependencies.
- Review sequence use and default ACLs by creator role/object type.
- Preserve authenticated SELECT/INSERT/UPDATE/DELETE while invoker RPCs and triggers depend on them.
- Do not change global public-schema defaults without a separate review of non-ERP objects.
- Do not revoke trigger/helper EXECUTE indiscriminately.
- Only after evidence and regression pass may a narrow ACL migration be designed. Do not prepare a blanket revoke from this runbook.

## 2. Apply and test the draft RPC hardening in staging

Apply one migration at a time, in numeric order, with its matching regression script immediately afterward:

| Migration | Regression |
|---|---|
| `upgrade-15.sql` | `tests/upgrade-15-product-rpc-regression.sql` |
| `upgrade-16.sql` | `tests/upgrade-16-fawry-rpc-regression.sql` |
| `upgrade-17.sql` | `tests/upgrade-17-cash-opening-rpc-regression.sql` |
| `upgrade-18.sql` | `tests/upgrade-18-manual-cash-movement-rpc-regression.sql` |
| `upgrade-19.sql` | `tests/upgrade-19-party-rpc-regression.sql` |
| `upgrade-20.sql` | `tests/upgrade-20-party-transaction-rpc-regression.sql` |
| `upgrade-21.sql` | `tests/upgrade-21-maintenance-rpc-regression.sql` |
| `upgrade-22.sql` | `tests/upgrade-22-settings-rpc-regression.sql` |
| `upgrade-23.sql` | `tests/upgrade-23-sale-imei-regression.sql` |
| `upgrade-24.sql` | `tests/upgrade-24-return-regression.sql` |
| `upgrade-25.sql` | `tests/upgrade-25-fawry-chronology-regression.sql` |
| `upgrade-26.sql` | `tests/upgrade-26-rpc-validation-regression.sql` |
| `upgrade-27.sql` | `tests/upgrade-27-shop-profile-privilege-regression.sql` |

Use synthetic users and disposable products, parties, accounts, and invoices only. Each rollback-based test must finish with ROLLBACK and leave fixture state unchanged. Stop on the first failure; do not continue to later migrations until the failure is understood.

### Required extended tests beyond the current regression files

- Upgrade 23: tracked and untracked sale paths; exact selected unit IDs; wrong-owner/product/status IDs; duplicate IDs; sale/payment/cash atomicity.
- Upgrade 24: partial sale and purchase returns, over-return rejection, payment/cash/party ledger consistency, IMEI mappings, SQL NULL/malformed JSON rejection. Run a two-session concurrent over-return test.
- Upgrade 25: predecessor/successor close chain, historical edit, nonzero top-up cash movement, stable source UUID. Run two concurrent close writes in independent sessions.
- Upgrade 26: positive ordinary purchase and partial payment; verify invoice totals, inventory, weighted-average cost, supplier ledger, purchase payment and cash movement linkage. Repeat with IMEI-tracked single-SIM and dual-SIM units; test duplicate/invalid IMEI and quantity mismatch rollback. Positive expense and cash-transfer paths must verify exactly one expense/outflow and paired transfer movements with unchanged combined balance.
- Upgrade 27: test viewer/admin under authenticated JWT claims, plus no-membership and cross-shop membership cases. Confirm app does not require subscription fields for non-admin roles.

## 3. Application integration checks

A source scan of `accounting/app.js` on the draft branch found these RPC calls:
`erp_my_shop_profile`, `erp_create_product_with_optional_imei`, `erp_create_fawry_transaction`, `erp_save_fawry_daily_close`, `erp_init_cash_accounts`, `erp_save_cash_opening_balances`, `erp_transfer_cash`, `erp_create_manual_cash_movement`, `erp_create_sale`, `erp_create_party`, `erp_create_party_transaction`, `erp_create_purchase`, `erp_create_maintenance_order`, `erp_save_shop_settings`, `erp_record_expense`, `erp_post_stock_count`, and `erp_post_return`.

A simple static scan found no direct `.from(...).insert/upsert/update/delete` patterns in the current `accounting/app.js`. This is not a runtime or complete semantic proof.

After migrations/tests:
- Open the app using a staging-only Supabase configuration and a synthetic account.
- Exercise every RPC-backed workflow from the UI.
- Inspect browser/network errors and PostgreSQL logs.
- Verify all reads remain owner-scoped.
- Verify backup/export and invoice printing.
- Confirm the public storefront and `public.products` remain unchanged.

## 4. Release decision

A staging pass is acceptable only when:
- All migrations 15–27 apply cleanly in order.
- Every matching regression passes.
- Extended positive-path, rollback, IMEI, and concurrency tests pass.
- The owner-FK evidence has no unexplained cross-owner/orphan relationships.
- Exact ACL evidence is reviewed against the function/trigger dependency map.
- Authenticated DML remains available wherever SECURITY INVOKER workflows require it.
- App integration smoke tests pass against staging.

Even after a single-owner staging pass, this does **not** make the ERP Multi-Shop ready. Do not onboard another shop. Multi-Shop requires a separate complete membership/role authorization design, shop-scoped checks in every RPC/read/export/storage path, tenant-safe relationships, billing enforcement, and two-shop adversarial tests.

## 5. Current verification statement

At the time this runbook was added:
- GitHub branch content has been reviewed statically.
- Purchase RPC source-to-source comparison is documented in `ERP-FIFTH-PASS-REVIEW.md`.
- Owner/FK and ACL audit SQL files are prepared.
- No Supabase staging connection is active in this work session.
- No PostgreSQL parser/runtime, concurrency, or staging regression test has been run here.
- No production SQL, ACL change, merge to `main`, or deployment has occurred.
