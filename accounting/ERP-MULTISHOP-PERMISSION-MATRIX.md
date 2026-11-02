# AL GABAS ERP — Multi-Shop Permission Matrix

**Status:** design only; not deployed.  
**Target branch:** `erp-security-fixes-draft`  
**Production branch:** `main`

## Security model

- A shop is the tenant boundary. `shop_id` determines data ownership after the tenant cutover.
- `owner_id` remains a legacy creator/ownership field during migration; it is not the tenant authorization boundary.
- A user may have memberships in more than one shop. Every request must be authorized against the selected shop and the user's current active membership.
- The client may send a requested `shop_id` as context, but the database must validate membership, status, role, and subscription on every operation. A client-supplied ID is never proof of access.
- All business writes are performed through narrowly scoped RPCs. Direct REST INSERT/UPDATE/DELETE on business tables are not granted to browser roles after the complete RPC migration and tests pass.
- RLS remains enabled on every tenant table. Policies are shop-scoped and role-aware. RPC authorization is an additional boundary, not a replacement for RLS.
- The matrix below is the target policy, not a statement that current production already enforces it.

## Role meanings

| Role | Intended responsibility |
|---|---|
| `owner` | Full shop control, membership/role management, billing and all business workflows |
| `admin` | Day-to-day shop administration and all business workflows; cannot transfer ownership or bypass billing controls |
| `accountant` | Financial records, invoices, parties/ledgers, cash, expenses, Fawry, reports and returns |
| `sales` | Customer-facing product lookup, sales, customer records and sales returns |
| `inventory` | Products, serial units, purchases, stock counts and purchase returns |
| `technician` | Maintenance orders and the limited product/device information needed to service a device |
| `viewer` | Read-only access to explicitly permitted operational and report data |

## Target table access matrix

Legend: **R** = SELECT through shop-scoped RLS; **RPC** = write only through an authorized business RPC; **—** = no access by default. Direct browser table writes are **none** for all roles after cutover.

| ERP table / group | owner | admin | accountant | sales | inventory | technician | viewer |
|---|---:|---:|---:|---:|---:|---:|---:|
| `erp_products` | R/RPC | R/RPC | R | R | R/RPC | R (limited fields/view) | R |
| `erp_product_units` | R/RPC | R/RPC | R | R (sale lookup only) | R/RPC | R (device lookup only) | R (limited) |
| `erp_sales_invoices`, `erp_sales_invoice_items`, `erp_sales_payments`, `erp_sales_invoice_item_units` | R/RPC | R/RPC | R/RPC | R/RPC | R | — | R |
| `erp_purchase_invoices`, `erp_purchase_invoice_items`, `erp_purchase_payments`, `erp_purchase_invoice_item_units` | R/RPC | R/RPC | R/RPC | — | R/RPC | — | R |
| `erp_parties` | R/RPC | R/RPC | R/RPC | R/RPC (customer scope) | R (supplier scope) | — | R (limited) |
| `erp_party_transactions` | R/RPC | R/RPC | R/RPC | R/RPC (sales-linked/customer scope) | R (purchase-linked/supplier scope) | — | R (limited) |
| `erp_cash_accounts`, `erp_cash_movements`, `erp_cash_transfers` | R/RPC | R/RPC | R/RPC | — | — | — | — |
| `erp_fawry_transactions`, `erp_fawry_daily_closings` | R/RPC | R/RPC | R/RPC | — | — | — | — |
| `erp_expenses` | R/RPC | R/RPC | R/RPC | — | — | — | R (optional summary only) |
| `erp_stock_counts`, `erp_stock_count_items` | R/RPC | R/RPC | R | — | R/RPC | — | R |
| `erp_returns`, `erp_return_items` | R/RPC | R/RPC | R/RPC | R/RPC (sales returns only) | R/RPC (purchase returns only) | — | R |
| `erp_maintenance_orders` | R/RPC | R/RPC | R (optional) | R/RPC (intake only) | — | R/RPC | R (limited) |
| `erp_shop_settings` | R/RPC | R/RPC (non-ownership settings) | R (invoice display fields only) | R (invoice display fields only) | R (operational display fields only) | R (limited) | R (limited) |
| `erp_shops` | R/RPC | R | R (profile only) | R (profile only) | R (profile only) | R (profile only) | R (profile only) |
| `erp_shop_memberships` | R/RPC | R/RPC (cannot grant owner) | — | — | — | — | self-read only |
| `erp_shop_subscriptions` | R/RPC | R (status only) | — | — | — | — | — |
| `erp_shop_audit_log` | R | R | — | — | — | — | — |

### Important permission refinements

1. The table matrix is a coarse target. Where a table contains mixed workflows (especially returns, parties, maintenance, and settings), the RPC must enforce the exact action and role. Do not grant a broad role merely because one action is needed.
2. For example, a `sales` member may create a sales return but must not return a purchase; an `inventory` member may create a purchase return but must not return a sale.
3. A sales user may need to choose a payment account during a sale without seeing the cash ledger or balances. Provide a narrow RPC or safe view returning allowed account labels, not broad cash-table access.
4. A technician should not receive full customer financial history merely to open a maintenance ticket. Use limited views/RPC return fields where needed.
5. Viewer access should be explicitly selected per screen/report. Do not automatically grant every ERP SELECT table.
6. Subscription state is not a role. A valid role does not override a suspended shop or expired plan's write restrictions.

## RPC authorization matrix

All writes must validate `auth.uid()`, active `shop_id` membership, role, shop status, and subscription entitlement inside the database. The client must not be trusted to enforce roles by hiding buttons.

| RPC workflow | Allowed roles (target) |
|---|---|
| Create shop / initial owner membership | Authenticated user creating their own new shop; server creates owner membership |
| Invite member / change non-owner role / suspend membership | owner; admin only if explicitly allowed and never for owner transfer |
| Transfer ownership / close shop | owner-only, separate confirmation and audit |
| Create product + optional IMEI unit atomically | owner, admin, inventory |
| Record Fawry transaction / daily close | owner, admin, accountant |
| Save opening cash balances / manual cash movement / cash transfer | owner, admin, accountant |
| Create party / party ledger transaction | owner, admin, accountant; sales or inventory only through narrowly scoped customer/supplier workflows |
| Create maintenance order | owner, admin, technician; sales may submit intake only |
| Save shop settings | owner, admin |
| Create sale | owner, admin, accountant, sales |
| Create purchase | owner, admin, accountant, inventory |
| Record expense | owner, admin, accountant |
| Post stock count | owner, admin, inventory |
| Post sales return | owner, admin, accountant, sales |
| Post purchase return | owner, admin, accountant, inventory |
| Initialize cash accounts | owner/admin/accountant; idempotent and shop-scoped |
| Read shop profile / list shops for switcher | active member; return only shops where the caller has active membership |
| Export / backup current shop | owner/admin; accountant only if a separate export permission is approved |

## Required implementation rules

- Prefer a single authorization helper that checks membership and returns the verified role, but ensure it cannot be called by arbitrary users to bypass a workflow's role requirements.
- Every RPC receives `p_shop_id` (except first-shop creation), validates it against the caller's active membership, and scopes every read/write/lock to it.
- Use SECURITY DEFINER only where necessary to permit writes after browser table-write grants are removed. Every such function must have a fixed safe `search_path`, explicit authorization checks, exact EXECUTE grants, and no unsafe dynamic SQL. Do not assume SECURITY INVOKER can write after table DML is revoked.
- Revoke default PUBLIC/anon function execution using exact signatures only after a complete function inventory. Preserve required trigger/helper execution behavior.
- Use shop-aware composite foreign keys for parent-child links (invoice lines, product units, payment rows, return rows, party ledgers, cash transfers, stock count items and IMEI mappings).
- RLS policies must use the verified `shop_id` membership. Role checks belong in policies for direct reads and in RPCs for writes.
- Do not make `shop_id` NOT NULL or remove owner-based policies until backfill, orphan, relationship, and isolation checks pass in a separate test project.

## Current implementation gap

Upgrades 13 and 14 add shop metadata, nullable `shop_id` columns, an initial-shop backfill, and a read-only profile function. They do not yet provide multi-shop switching, membership-based authorization for business tables, role-enforced business RPCs, or tenant-aware direct REST reads/writes. The app's current `erp_my_shop_profile()` call returns at most one shop; it is not a shop list/switcher API.

**This matrix is a target specification only. No production permissions have been changed.**
