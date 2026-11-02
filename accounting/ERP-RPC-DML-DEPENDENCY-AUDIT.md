# ERP RPC and DML Dependency Audit

**Status:** static source audit only; no database ACL output has been captured in this step.  
**Branch:** `erp-security-fixes-draft`  
**Production baseline:** `main`  
**Scope:** ERP only. `public.products`, storefront grants, and product-admin workflows are excluded.

## 1. Current application write-path status

A static scan of the current `accounting/app.js` after upgrades 15–22 found no remaining direct calls matching:

- `.insert(...)`
- `.upsert(...)`
- `.update(...)`
- `.delete(...)`

The eight formerly direct-write workflows now call these exact RPCs:

| Workflow | RPC | Migration |
|---|---|---|
| Product + optional IMEI | `erp_create_product_with_optional_imei` | `upgrade-15.sql` |
| Fawry transaction | `erp_create_fawry_transaction` | `upgrade-16.sql` |
| Three cash opening balances | `erp_save_cash_opening_balances` | `upgrade-17.sql` |
| Manual cash movement | `erp_create_manual_cash_movement` | `upgrade-18.sql` |
| Customer/supplier | `erp_create_party` | `upgrade-19.sql` |
| Party ledger entry | `erp_create_party_transaction` | `upgrade-20.sql` |
| Maintenance intake | `erp_create_maintenance_order` | `upgrade-21.sql` |
| Shop settings | `erp_save_shop_settings` | `upgrade-22.sql` |

This is source-level verification only. It does not prove the RPCs have run successfully in PostgreSQL.

## 2. Why authenticated table DML must not be revoked yet

All eight new RPCs currently use **SECURITY INVOKER**. Static review of existing business functions also identifies important SECURITY INVOKER workflows:

| Existing function | Tables written/read in reviewed function body |
|---|---|
| `erp_create_sale` | products, product units, sales invoices/items/payments, cash movements |
| `erp_create_purchase` | parties, products, purchase invoices/items/payments, party transactions, cash movements |
| `erp_record_expense` | expenses, cash movements |
| `erp_post_stock_count` | stock counts/items, products, product units |
| `erp_post_return` | returns/items, sales/purchase invoices and items, products, cash movements, party transactions |
| `erp_transfer_cash` | cash accounts, cash movements, cash transfers |
| `erp_save_fawry_daily_close` | Fawry closings, cash movements |
| `erp_init_cash_accounts` | cash accounts |

The trigger functions protecting cash balances, opening balances, and IMEI/return mappings are also invoker-context functions in the reviewed migrations.

**Conclusion:** moving browser writes into invoker RPCs does not remove the authenticated role's underlying table DML requirement. PostgreSQL executes these functions with the caller's privileges. Revoking authenticated INSERT/UPDATE/DELETE now would break business RPCs and/or trigger operations even though the browser no longer sends direct writes.

Do not revoke authenticated table DML until each affected write RPC and trigger dependency is deliberately migrated to a safe execution model, with explicit owner/shop authorization and staging regression coverage. SECURITY DEFINER is not a blanket fix: every such function must be reviewed for RLS bypass, explicit ownership predicates, fixed search_path, exact EXECUTE grants, and safe helper/trigger dependencies.

## 3. Next read-only ACL capture required

Run `ERP-MULTISHOP-ACL-REVIEW-DRAFT.sql` in the separate staging project and retain the complete output. In particular, review:

1. Effective privileges for `anon`, `authenticated`, `PUBLIC`, and service roles on each ERP table.
2. Whether broad privileges are direct grants or inherited through PUBLIC.
3. Existing sequence privileges and whether any ERP sequence is actually used by client-invoker functions.
4. Exact function signatures, SECURITY INVOKER/DEFINER mode, owners, function configuration, and effective EXECUTE for anon/authenticated.
5. Default ACLs separately for each object creator and object type.
6. RLS enabled/FORCE state and every ERP policy.

Do not prepare a final REVOKE migration from raw ACL arrays alone. Effective privileges and PUBLIC inheritance must be resolved first.

## 4. ACL changes intentionally deferred

- **Authenticated SELECT/INSERT/UPDATE/DELETE:** preserved. Invoker RPCs still depend on table privileges.
- **Anon table privileges:** no migration authored yet because the live/staging effective ACL output is not available in this coding session, including possible PUBLIC inheritance.
- **TRUNCATE/TRIGGER/REFERENCES/MAINTAIN:** removal is planned for client roles after exact effective ACL and dependency review.
- **Function EXECUTE:** no broad revoke. Client RPCs, trigger functions, and helper functions must be classified by exact signature and call path.
- **Default privileges:** no change. Public-schema default ACLs apply to future non-ERP objects too; changing them can affect storefront or unrelated future objects. A safe strategy requires a separate schema/creator plan or an explicitly approved global public-schema default policy.
- **`public.products`, `product_admins`, storefront grants/policies/code:** untouched and out of scope.

## 5. Release gates

1. Apply upgrades 15–22 in order only in a separate Supabase staging project.
2. Run each matching rollback-based regression file using a synthetic auth user; confirm the app bundle matches the migrations.
3. Run the complete existing single-shop regression suite, including sale, purchase, return, stock count, cash transfer, Fawry close, and IMEI behavior.
4. Capture and review effective ACL outputs.
5. Only then prepare a narrow ACL migration that preserves invoker RPC requirements.
6. Do not run SQL on production, merge to `main`, deploy, or onboard another shop without explicit approval.
