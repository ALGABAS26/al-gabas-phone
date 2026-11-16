# AG System SaaS / Multi-shop readiness — audit (2026-11-17)

## Scope and safety
Read-only inspection of the linked Supabase project and the current work branch. No production DDL, data, Auth settings, secrets, Edge Function deployments, or releases were changed by this audit.

## What already exists
- `erp_shops`, `erp_shop_memberships`, `erp_shop_subscriptions`, and `erp_shop_audit_log`.
- `shop_id` columns and foreign keys exist on the current ERP business tables.
- `accounting/app.js` calls `erp_my_shop_profile()` and displays the returned shop name/role/subscription.
- Existing membership roles include owner/admin/accountant/sales/inventory/technician/viewer.
- Shop subscription statuses include trial/active/past_due/suspended/cancelled/expired.

## Blocking security gaps found
1. All 23 current ERP business-table policies inspected still authorize by `owner_id = auth.uid()`; they do not authorize by active shop membership and shop status.
2. The browser app still writes `owner_id` on direct CRUD operations and does not consistently set `shop_id`. The existing profile chip is display-only; it is not an authorization gate.
3. `erp_create_sale` and the other posting RPCs use the caller's `auth.uid()` as owner and do not consistently propagate or validate `shop_id`. A shop member cannot safely share one shop's records yet.
4. The existing `erp_my_shop_profile()` only returns active memberships and does not reject a suspended shop/subscription. A stale signed-in session can therefore continue to call the existing owner-based policies.
5. Some existing shop-management and WhatsApp ledger RPCs are SECURITY DEFINER. They require explicit privilege, ownership, search_path, and RLS review before any new admin/onboarding workflow is exposed.
6. Existing business rows include nullable `shop_id`; a safe migration must map each legacy owner's records to their existing shop before enforcing NOT NULL. Do not guess this mapping or update production rows automatically.

## Required product behavior
- A new shop owner signs up with Supabase Auth, then creates one shop in `pending` state. The shop cannot access ERP data until the platform owner approves it.
- The platform owner is identified server-side using a secret allowlist of immutable Auth user UUIDs (not email or user-editable user_metadata).
- Only a server-side admin endpoint using service-role credentials can list shops or change shop/subscription status. Every action writes an audit event.
- Suspension changes the shop license state and blocks reads/writes at RLS / database RPC level, not merely in the UI. It should take effect for already-issued sessions on the next database request.
- Each shop's data is partitioned by `shop_id`; memberships determine which staff can access it. A user must never choose or submit an arbitrary `shop_id` without server-side membership validation.
- The existing AL GABAS shop must remain mapped to its current records and owner. New shop registration must not alter the existing account.

## Safe implementation sequence
1. Create a Supabase development branch (not production) and confirm its hourly cost before creating it.
2. Snapshot schema, policies, constraints, function definitions, and test fixtures on that branch.
3. Add onboarding and platform-admin RPC/Edge Function contracts; never put service-role keys in Android, Windows, or browser code.
4. Backfill `shop_id` on the development branch only, mapping by the existing owner membership; stop if any owner maps to zero or multiple candidate shops.
5. Replace owner-only RLS on every ERP table with active membership + active shop + valid subscription checks. Add explicit role permissions and WITH CHECK predicates.
6. Update all browser CRUD and all posting RPCs to use the selected shop context; add cross-shop and suspended-shop tests.
7. Add registration, pending-approval, suspended-account and owner-only administration screens.
8. Promote the migration only after independent review, full test matrix, backup and explicit production approval.

## Required acceptance tests
- Shop A cannot read/write Shop B records, even when it knows a row UUID.
- An employee can only access the shop to which they have an active membership and only within their role.
- A suspended shop is denied on fresh requests even with a still-valid JWT.
- A suspended membership is denied without suspending other staff or other shops.
- A new registrant cannot create an active shop or assign themselves owner/admin privileges for another shop.
- A non-platform-owner cannot list all shops or change a subscription/license.
- Re-enabling a shop restores access without changing any business rows.
- Existing AL GABAS records remain visible to the existing owner and no duplicate shop is created.

## Current state
This is an audit and implementation specification only. No production changes were made. The linked project currently has no Supabase development branches available. A new development branch was quoted at **$0.01344/hour** and requires cost approval before creation.

## Supabase Security Advisor findings (read-only)
The current Security Advisor also reports:
- Two SECURITY DEFINER functions executable by `anon`: `erp_my_shop_profile()` and `rls_auto_enable()`.
- Three SECURITY DEFINER functions executable by `authenticated`: the above plus `is_product_admin()`.
- Mutable search_path warnings on `erp_check_imei_unique()` and `erp_imei_luhn_valid()`.
- Leaked-password protection is disabled.
- Private WhatsApp delivery ledger has RLS enabled and no policies; this is expected only if all direct grants remain revoked and access is exclusively through reviewed server-side RPCs.
These are audit findings only. Do not revoke grants, alter function security, or change Auth settings on production as part of this work without a reviewed migration and rollback plan.

## Evidence from existing application code
The client still inserts rows with `owner_id: session.user.id` and often omits `shop_id`; invoice printing reads the shop settings as a single row. The app does not yet use shop_id as its tenant boundary. The new SaaS control plane must therefore be implemented as a coordinated migration, not a quick registration form.
