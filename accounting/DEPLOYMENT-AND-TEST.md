# AL GABAS STORE ERP — Deployment and final test checklist

## Current database state
The owner previously confirmed that `schema.sql` and `upgrade-02.sql` through `upgrade-07.sql` were applied successfully. The later migrations are committed but have **not** been confirmed as applied.

## Remaining migrations (do not skip or reorder)
1. `upgrade-08.sql` — stock counts and returns.
2. `upgrade-09.sql` — transfers between cash accounts.
3. `upgrade-10.sql` — prevents negative cash balances and blocks ambiguous returns for products tracked by IMEI.

Run each migration once, in order, in the Supabase SQL Editor. Do not run upgrade-09 or upgrade-10 before upgrade-08. Do not run the same migration repeatedly as a substitute for checking its result.

## Important behavior
- Products with registered IMEI units cannot be returned through the generic return screen until the original serial is explicitly selected. This is intentional protection; otherwise stock quantity and serial availability could disagree.
- Cash outflows are rejected if they would make the selected account negative. This covers manual movements and cash movements posted by sales/purchases, expenses, Fawry top-ups, returns, and transfers.
- Transfers are movements between accounts, not sales or expenses.
- The backup export includes the cash transfer ledger.

## Final verification checklist
After all migrations are applied, test with a disposable product and small values:
- Create a non-IMEI product, purchase it, and confirm quantity and cash decrease.
- Sell part of the quantity, confirm stock and cash increase.
- Create a sale return against the exact invoice line; confirm returnable quantity decreases on reload and stock increases.
- Create a purchase return; confirm stock decreases and supplier balance is reduced.
- Attempt an outflow greater than the account balance; it must be rejected without creating a movement.
- Transfer between two cash accounts; total cash across the three accounts must remain unchanged.
- Attempt a same-account transfer; it must be rejected.
- Run stocktake and inspect its item history.
- Export JSON backup and a CSV table; verify the downloaded files open.
- Print a sales and purchase invoice from Android.
- Verify Fawry, maintenance, expenses, settings, supplier history, and reports.
- Install/update the Android APK and confirm the app loads the newest script and logo.

## Limits still to address before selling to multiple shops
This version remains a single-owner ERP. It is not yet a multi-tenant SaaS product. Before onboarding other shops, implement and test tenant membership, tenant-scoped RLS for every ERP table and RPC, owner/admin roles, subscription status/expiry, and a secure shop onboarding flow. Do not share the current owner login with another shop.
