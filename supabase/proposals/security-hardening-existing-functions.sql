-- Security hardening for existing AG System database helper functions.
-- Applied to both AL GABAS PHONE (production) and AL GABAS (test).
-- These changes preserve the existing event trigger and authenticated shop-profile RPC.

-- The event trigger remains attached to ensure_rls; only direct API execution is revoked.
revoke all on function public.rls_auto_enable() from public, anon, authenticated;

-- Both functions reference public tables explicitly and use only built-in SQL functions/operators.
alter function public.erp_check_imei_unique() set search_path = '';
alter function public.erp_imei_luhn_valid(text) set search_path = '';

-- The shop-profile RPC is used by signed-in app sessions, never by anonymous callers.
revoke all on function public.erp_my_shop_profile() from public, anon;
grant execute on function public.erp_my_shop_profile() to authenticated, service_role;
