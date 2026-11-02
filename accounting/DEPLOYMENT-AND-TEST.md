# AL GABAS STORE ERP — Deployment and final test checklist

## Current database state
The owner reports that `schema.sql` and `upgrade-02.sql` through `upgrade-14.sql` were applied successfully. This is user-reported and has not been independently verified against the live database. Do not rerun these migrations to troubleshoot.

## Immediate next database step
Run `TENANT-READINESS-AUDIT.sql` in Supabase SQL Editor and save the result sets for review. It contains SELECT statements only, does not change the database, and does not inspect `public.products`. Use the output to plan and verify tenant isolation in a separate Supabase test project. Do not make live production RLS/RPC changes as part of this audit.

## Important behavior
- For a product that is already tracked by IMEI, every new purchase line must include serial data for each purchased device. For a newly tracked product, enable “تتبع IMEI” on the purchase line and enter one device per line; the second IMEI is optional. IMEIs must be 15 digits and pass the Luhn check.
- The database rejects duplicate IMEIs and rolls back the whole purchase if serial registration fails.
- Purchase returns of tracked products are limited to serials linked to the original purchase line. The current return workflow automatically selects available linked serials in oldest-first order; the operator cannot manually choose a serial in the return screen yet.
- New sales associate sold IMEI unit rows with their exact invoice line. Tracked sale returns use available serials linked to that original sales line, oldest-first. Old sales invoices created before upgrade 11 have no exact serial association; tracked-device returns against those old invoices remain blocked.
- Cash outflows are rejected if they would make the selected account negative. This covers manual movements and cash movements posted by sales/purchases, expenses, Fawry top-ups, returns, and transfers.
- Transfers between cash accounts are movements, not sales or expenses.
- The backup export includes the cash transfer ledger.

## Functional verification checklist
Use disposable products and small values for additional functional verification:
- Create a non-IMEI product, purchase it, and confirm quantity and cash movement.
- Purchase a tracked device with one IMEI; verify the product unit and purchase-line mapping.
- Purchase a dual-SIM tracked device with two distinct IMEIs; verify both serials are stored.
- Attempt duplicate or invalid IMEI data; the whole purchase must fail without changing stock, invoice, or cash.
- Sell part of the quantity; confirm stock and cash update and verify sale-line IMEI mapping.
- Create sale and purchase returns against exact invoice lines; confirm returnable quantities decrease and serial states become returned.
- Attempt a return beyond the remaining invoice-line quantity; it must fail.
- Attempt an outflow greater than the account balance; it must be rejected without creating a movement.
- Transfer between two cash accounts; verify both ledger legs and unchanged combined cash. Attempt a same-account transfer; it must be rejected.
- Run stocktake and inspect its item history.
- Export JSON backup and a CSV table; verify downloaded files open.
- Print sales and purchase invoices from Android.
- Verify Fawry, maintenance, expenses, settings, supplier history, and reports.
- Install/update the Android APK and confirm the app loads the newest script and original logo.

## SaaS release blockers
This version remains a single-owner ERP, not a multi-tenant SaaS product. Do not share the current login with another shop or create/invite customer shops yet.

Before onboarding other shops, implement and test tenant membership, tenant-scoped RLS for every ERP table and RPC, owner/admin roles, subscription status/expiry, secure shop onboarding, and tenant-aware exports/backups/storage. Direct REST table access is a separate security boundary; changing RPCs alone is insufficient. Test with two synthetic shops and multiple roles in a separate Supabase test project, including cross-shop reads/writes, forged shop IDs, cross-shop foreign references, returns, cash transfers, membership revocation, subscription restrictions, exports, backups, and storage URLs. Every cross-shop operation must fail at the database boundary.

## Upgrade 13 and 14 scope
Upgrade 13 is an additive foundation: it creates shop/membership/subscription/audit metadata and adds nullable `shop_id` columns with a backfill for existing owner rows. It does not enforce shop isolation or replace current owner-based RLS/RPC authorization.

Upgrade 14 adds a read-only RPC for the signed-in user's shop profile and SELECT policies for their own shop metadata. It does not enable multi-shop ERP access. If the app header displays “تعذر تحميل بيانات المحل”, capture the exact error; do not attempt to fix it by rerunning migrations.

## Read-only tenant readiness audit
`TENANT-READINESS-AUDIT.sql` is a diagnostic snapshot only. It reports ERP ownership/tenant columns, RLS state, policies, SECURITY DEFINER functions, approximate row statistics, and shop metadata counts. It does not alter data, policies, functions, or the public storefront, and it does not inspect `public.products`. Its output is needed before preparing the tenant migration for a separate test project.
