# ERP Write-Path Hardening — Draft Plan
Status: review draft only. Not deployed. No production SQL has been executed.
Target branch: erp-security-fixes-draft
Production app.js remains unchanged.

## Scope boundary
- ERP tables only.
- Never modify storefront public.products.
- Existing invoice, expense, cash-transfer, stock-count and return RPCs are retained and audited; do not duplicate them.
- No broad ACL revokes until every direct-write caller is migrated and tested.

## Confirmed direct-write call sites in accounting/app.js
| UI workflow | Current write | Required replacement |
|---|---|---|
| Product create + optional IMEI | INSERT erp_products, then INSERT erp_product_units | erp_create_product_with_unit: one transaction; validates input, owner, barcode uniqueness, IMEI format/Luhn/uniqueness, quantity=1 when tracked |
| Fawry transaction | INSERT erp_fawry_transactions | erp_record_fawry_transaction: validate type/status/amount/commission/fee and authenticated owner |
| Cash opening balances | UPSERT erp_cash_accounts | erp_save_cash_opening_balances: validate all three allowed account codes and amounts; preserve opening-balance guard |
| Manual cash movement | INSERT erp_cash_movements | erp_record_cash_movement: validate account exists, date, direction, amount, description; preserve balance triggers |
| Party create | INSERT erp_parties | erp_create_party: validate type/name/opening balance |
| Party ledger transaction | INSERT erp_party_transactions | erp_record_party_transaction: lock/check party ownership and validate transaction |
| Maintenance intake | INSERT erp_maintenance_orders | erp_create_maintenance_order: validate required fields/status/costs and generate ticket safely |
| Shop settings | UPSERT erp_shop_settings | erp_save_shop_settings: owner-derived upsert, EGP only |

## Existing RPCs to retain and harden
- erp_create_sale
- erp_create_purchase
- erp_record_expense
- erp_save_fawry_daily_close
- erp_transfer_cash
- erp_post_stock_count
- erp_post_return
- erp_init_cash_accounts
- erp_my_shop_profile

## Confirmed validation gaps / review items
1. erp_record_expense: explicit NULL validation is required for p_account_code; SQL NOT IN does not reject NULL.
2. erp_save_fawry_daily_close: reject NULL date and all NULL numeric inputs; serialize same-owner/same-day updates; historical edits must not silently leave later opening balances inconsistent. Choose and implement a clear policy (reject historical edits when later closes exist, or recalculate a validated chain).
3. erp_transfer_cash: explicit NULL checks and explicit account existence checks are required before balance arithmetic.
4. erp_post_return: cash movement source_id currently needs stable traceability to the return record, not an unrelated random UUID.
5. IMEI validation: unique indexes currently protect same-slot duplicates, but cross-slot duplication requires the trigger; retain and test it. Product + unit creation must be atomic.
6. Multi-shop tables exist, but the app and core policies are still owner-scoped. Do not advertise SaaS/multi-tenant readiness until membership/role checks and shop_id isolation are implemented end-to-end.

## App integration requirements
- Replace only the eight direct writes listed above with RPC calls.
- Keep SELECT/read flows unchanged in this migration.
- Disable submit buttons during requests; surface Arabic errors without exposing secrets.
- Refresh the same affected views after successful RPC completion.
- Do not send owner_id from browser for write authority; derive it from auth.uid() inside each function.
- Avoid changing unrelated UI, layout, APK metadata, or storefront config in this phase.

## Required regression tests before release
1. Create normal product; create product with one/two IMEIs; duplicate IMEI rejected; invalid Luhn rejected; failed unit insert leaves no orphan product.
2. Fawry valid/invalid enum, zero/negative/null amount, commission/fee bounds.
3. Opening balance cannot be changed after movements where guard prohibits it.
4. Manual cash movement cannot overdraw an account; invalid account/date/direction rejected.
5. Party transaction for another owner's party rejected; zero/negative amount rejected.
6. Maintenance required fields, costs, status and duplicate ticket behavior.
7. Settings upsert does not create duplicate owner rows; currency remains EGP.
8. Existing sale, purchase, expense, transfer, stock count and return workflows still post exactly one set of linked records.
9. RLS and ownership checks verified using two distinct authenticated users.
10. Backup/export and all read-only screens continue to work.

## Release gates
- First commit migration SQL and app changes only to this draft branch.
- Review SQL against the exact current schema and function signatures.
- Run SQL in a staging project first; compare row counts and ledger balances.
- User approval is required before any production SQL, main-branch merge, or live deployment.
