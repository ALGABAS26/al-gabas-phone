-- AL GABAS STORE — Read-only tenant readiness audit
-- SAFE: SELECT statements only. This script does not create, update, or delete anything.
-- Run in Supabase SQL Editor only when asked to collect a schema snapshot.
-- It does not inspect public.products and does not expose customer/business row contents.

-- 1) ERP tables and whether tenant/legacy ownership columns exist.
select
  c.table_schema,
  c.table_name,
  bool_or(c.column_name = 'owner_id') as has_owner_id,
  bool_or(c.column_name = 'shop_id') as has_shop_id,
  string_agg(c.column_name, ', ' order by c.ordinal_position) as relevant_columns
from information_schema.columns c
where c.table_schema = 'public'
  and c.table_name like 'erp_%'
  and c.column_name in ('owner_id', 'shop_id')
group by c.table_schema, c.table_name
order by c.table_name;

-- 2) RLS state for ERP and shop metadata tables.
select
  n.nspname as schema_name,
  cls.relname as table_name,
  cls.relrowsecurity as rls_enabled,
  cls.relforcerowsecurity as rls_forced
from pg_class cls
join pg_namespace n on n.oid = cls.relnamespace
where n.nspname = 'public'
  and cls.relkind in ('r', 'p')
  and (cls.relname like 'erp_%')
order by cls.relname;

-- 3) Policies currently attached to ERP and shop metadata tables.
select
  schemaname,
  tablename,
  policyname,
  permissive,
  roles,
  cmd,
  qual,
  with_check
from pg_policies
where schemaname = 'public'
  and tablename like 'erp_%'
order by tablename, policyname;

-- 4) Security-definer functions in the ERP namespace.
-- Review each function body before replacing or exposing it to tenant members.
select
  p.proname as function_name,
  pg_get_function_identity_arguments(p.oid) as identity_arguments,
  p.prosecdef as security_definer,
  p.provolatile as volatility,
  pg_get_userbyid(p.proowner) as function_owner,
  p.proconfig as function_settings
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname like 'erp_%'
order by p.proname, identity_arguments;

-- 5) Approximate row counts and last maintenance timestamps (statistics, not exact counts).
select
  schemaname,
  relname as table_name,
  n_live_tup as estimated_rows,
  last_analyze,
  last_autoanalyze
from pg_stat_user_tables
where schemaname = 'public'
  and relname like 'erp_%'
order by relname;

-- 6) Shop metadata health: counts only, no shop/customer details.
select 'erp_shops' as table_name, count(*)::bigint as row_count from public.erp_shops
union all
select 'erp_shop_memberships', count(*)::bigint from public.erp_shop_memberships
union all
select 'erp_shop_subscriptions', count(*)::bigint from public.erp_shop_subscriptions
union all
select 'erp_shop_audit_log', count(*)::bigint from public.erp_shop_audit_log
order by table_name;
