# AL GABAS STORE ERP — Deployment and final test checklist

## Current database state
The owner previously confirmed that `schema.sql` and `upgrade-02.sql` through `upgrade-07.sql` were applied successfully. Upgrades 08–13 are committed but have **not** been confirmed as applied.

## Remaining migrations (do not skip or reorder)
1. `upgrade-08.sql` — stock counts and returns.
2. `upgrade-09.sql` — transfers between cash accounts.
3. `upgrade-10.sql` — prevents negative cash balances and blocks ambiguous returns for products tracked by IMEI.
4. `upgrade-11.sql` — links sold IMEI units to exact sales invoice lines.
5. `upgrade-12.sql` — receives purchased IMEI units and links them to exact purchase invoice lines; enables tracked purchase returns.\n6. `upgrade-13.sql` — creates the initial shop/membership/subscription/audit foundation and adds nullable `shop_id` columns with a backfill for existing owner rows. It intentionally leaves current owner-based RLS and RPC behavior unchanged.

Run each migration once, in order, in the Supabase SQL Editor, after taking a restorable database backup and reviewing the complete SQL. Do not run a later migration before an earlier one, and do not repeat a migration to troubleshoot it. If any statement errors, stop and share the exact error; do not continue to the next file.

## Important behavior
- For a product that is already tracked by IMEI, every new purchase line must include one row of serial data per purchased device. For a newly tracked product, enable “تتبع IMEI” on the purchase line and enter one device per line; the second IMEI is optional. IMEIs must be 15 digits and pass the Luhn check.
- The database rejects duplicate IMEIs and rolls back the whole purchase if serial registration fails.
- Purchase returns of tracked products are limited to the serials linked to the original purchase line. The current return workflow automatically selects available linked serials in oldest-first order; it does not yet let the operator choose a particular serial manually.
- New sales automatically associate sold IMEI unit rows with their exact invoice line. Tracked sale returns use available serials linked to that original sales line, oldest-first. Old sales invoices created before upgrade 11 have no exact serial association; tracked-device returns against those old invoices remain blocked.
- Cash outflows are rejected if they would make the selected account negative. This covers manual movements and cash movements posted by sales/purchases, expenses, Fawry top-ups, returns, and transfers.
- Transfers between cash accounts are movements, not sales or expenses.
- The backup export includes the cash transfer ledger.

## IMEI receiving and return behavior
- Upgrade 12 records one or two validated 15-digit IMEI values for each tracked purchased device and links each unit to its exact purchase invoice line.
- IMEI check digits are validated in the database with Luhn; duplicate values are prevented by the product-unit uniqueness constraints.
- For tracked products, returns are currently FIFO: the database marks the oldest still-available unit linked to the exact original invoice line as returned. The operator does not select a specific serial in the return screen yet; this limitation is disclosed in the UI.
- Upgrade 12 has been repaired for SQL delimiter/truncated duplicate-tail issues and reviewed structurally, but has not been executed against the live Supabase database. It must still be tested on a separate test project before production.

## Final verification checklist
After all migrations are applied, test with disposable products and small values:
- Create a non-IMEI product, purchase it, and confirm quantity and cash decrease.
- Purchase a tracked device with one IMEI; verify the product unit and purchase-line mapping are created.
- Purchase a dual-SIM tracked device with two distinct IMEIs; verify both serials are stored.
- Attempt duplicate or invalid IMEI data; the entire purchase must fail without changing stock, invoice, or cash.
- Sell part of the quantity, confirm stock and cash increase, and verify sale-line IMEI mapping.
- Create sale and purchase returns against exact invoice lines; confirm returnable quantities decrease and serial states become returned.
- Attempt a return beyond the remaining invoice-line quantity; it must fail.
- Attempt an outflow greater than the account balance; it must be rejected without creating a movement.
- Transfer between two cash accounts; verify both ledger legs and unchanged combined cash. Repeat with the same amount/date to verify movement keys do not collide.
- Attempt a same-account transfer; it must be rejected.
- Run stocktake and inspect its item history.
- Export JSON backup and a CSV table; verify downloaded files open.
- Print sales and purchase invoices from Android.
- Verify Fawry, maintenance, expenses, settings, supplier history, and reports.
- Install/update the Android APK and confirm the app loads the newest script and original logo.

## Limits before selling to multiple shops
This version remains a single-owner ERP, not a multi-tenant SaaS product. Before onboarding other shops, implement and test tenant membership, tenant-scoped RLS for every ERP table and RPC, owner/admin roles, subscription status/expiry, and a secure shop onboarding flow. Do not share the current owner login with another shop.
\n\n## Upgrade 13 scope and SaaS gate\n\nUpgrade 13 is an additive foundation only. It creates tenant metadata tables and assigns existing ERP rows to an initial shop based on `owner_id`. It does **not** yet enforce shop isolation, does not replace existing RLS policies or business RPC authorization, and does not make the product ready for other shops. Existing ERP screens should continue using the current single-owner account. Do not create or invite customer shops yet. A later upgrade must add shop-aware RLS and shop-aware versions of every write RPC as one coordinated release, then update the frontend to select the active shop.\n