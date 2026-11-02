-- AL GABAS ERP — Read-only relationship, IMEI, and privilege audit
-- SAFE: this file contains SELECT statements only.
-- It does not read business descriptions, customer names, phone numbers, or public.products.
-- Run only in a review/test project or collect the result sets for review.
-- Do not use the generated SQL until its exact target tables/columns have been inspected.

-- 1) Foreign-key inventory, including ordered child/parent columns and validation state.
select
  ns.nspname as child_schema,
  child.relname as child_table,
  con.conname as constraint_name,
  string_agg(child_col.attname, ', ' order by child_key.ord) as child_columns,
  pns.nspname as parent_schema,
  parent.relname as parent_table,
  string_agg(parent_col.attname, ', ' order by parent_key.ord) as parent_columns,
  con.convalidated as is_validated,
  con.condeferrable as is_deferrable,
  con.condeferred as initially_deferred
from pg_constraint con
join pg_class child on child.oid = con.conrelid
join pg_namespace ns on ns.oid = child.relnamespace
join pg_class parent on parent.oid = con.confrelid
join pg_namespace pns on pns.oid = parent.relnamespace
join lateral unnest(con.conkey) with ordinality child_key(attnum, ord) on true
join lateral unnest(con.confkey) with ordinality parent_key(attnum, ord)
  on parent_key.ord = child_key.ord
join pg_attribute child_col
  on child_col.attrelid = child.oid and child_col.attnum = child_key.attnum
join pg_attribute parent_col
  on parent_col.attrelid = parent.oid and parent_col.attnum = parent_key.attnum
where con.contype = 'f'
  and ns.nspname = 'public'
  and (child.relname like 'erp\_%' escape '\' or parent.relname like 'erp\_%' escape '\')
group by ns.nspname, child.relname, con.conname, pns.nspname, parent.relname,
         con.convalidated, con.condeferrable, con.condeferred
order by child.relname, con.conname;

-- 2) Unique constraints and indexes, including partial-index definitions.
select
  schemaname,
  tablename,
  indexname,
  indexdef
from pg_indexes
where schemaname = 'public'
  and tablename like 'erp\_%' escape '\'
order by tablename, indexname;

-- 3) ERP tables' owner/shop columns and RLS state.
select
  c.relname as table_name,
  c.relrowsecurity as rls_enabled,
  c.relforcerowsecurity as rls_forced,
  bool_or(a.attname = 'owner_id') filter (where a.attnum is not null) as has_owner_id,
  bool_or(a.attname = 'shop_id') filter (where a.attnum is not null) as has_shop_id
from pg_class c
join pg_namespace n on n.oid = c.relnamespace
left join pg_attribute a
  on a.attrelid = c.oid and a.attnum > 0 and not a.attisdropped
where n.nspname = 'public'
  and c.relkind in ('r','p')
  and c.relname like 'erp\_%' escape '\'
group by c.relname, c.relrowsecurity, c.relforcerowsecurity
order by c.relname;

-- 4) Generate SELECT-only cross-owner diagnostics for simple single-column
-- foreign keys where both child and parent tables have owner_id.
-- This query returns SQL text only; it does not execute the generated statements.
select
  format(
    'select %L as fk_name, count(*)::bigint as cross_owner_rows from %I.%I c join %I.%I p on c.%I = p.%I where c.owner_id is distinct from p.owner_id;',
    con.conname,
    child_ns.nspname, child.relname,
    parent_ns.nspname, parent.relname,
    child_col.attname, parent_col.attname
  ) as read_only_diagnostic_sql
from pg_constraint con
join pg_class child on child.oid = con.conrelid
join pg_namespace child_ns on child_ns.oid = child.relnamespace
join pg_class parent on parent.oid = con.confrelid
join pg_namespace parent_ns on parent_ns.oid = parent.relnamespace
join pg_attribute child_col
  on child_col.attrelid = child.oid and child_col.attnum = con.conkey[1]
join pg_attribute parent_col
  on parent_col.attrelid = parent.oid and parent_col.attnum = con.confkey[1]
where con.contype = 'f'
  and cardinality(con.conkey) = 1
  and cardinality(con.confkey) = 1
  and child_ns.nspname = 'public'
  and parent_ns.nspname = 'public'
  and child.relname like 'erp\_%' escape '\'
  and parent.relname like 'erp\_%' escape '\'
  and exists (
    select 1 from pg_attribute a
    where a.attrelid = child.oid and a.attname = 'owner_id'
      and a.attnum > 0 and not a.attisdropped
  )
  and exists (
    select 1 from pg_attribute a
    where a.attrelid = parent.oid and a.attname = 'owner_id'
      and a.attnum > 0 and not a.attisdropped
  )
order by child.relname, con.conname;

-- 5) Duplicate IMEI counts across both IMEI slots for each owner.
-- The actual IMEI values are intentionally not returned.
with all_imeis as (
  select owner_id, imei1 as imei
  from public.erp_product_units
  where imei1 is not null and btrim(imei1) <> ''
  union all
  select owner_id, imei2 as imei
  from public.erp_product_units
  where imei2 is not null and btrim(imei2) <> ''
),
duplicates as (
  select owner_id, imei, count(*) as occurrences
  from all_imeis
  group by owner_id, imei
  having count(*) > 1
)
select
  count(*)::bigint as duplicated_imei_values,
  coalesce(sum(occurrences - 1), 0)::bigint as extra_occurrences,
  count(distinct owner_id)::bigint as affected_owners
from duplicates;

-- 6) IMEI mapping triggers and their function names.
select
  trigger_schema,
  event_object_table as table_name,
  trigger_name,
  action_timing,
  event_manipulation,
  action_orientation,
  action_statement
from information_schema.triggers
where trigger_schema = 'public'
  and (event_object_table like 'erp\_%' escape '\')
order by event_object_table, trigger_name, event_manipulation;

-- 7) RLS policies and their exact expressions.
select
  schemaname, tablename, policyname, permissive, roles, cmd, qual, with_check
from pg_policies
where schemaname = 'public'
  and tablename like 'erp\_%' escape '\'
order by tablename, policyname;

-- 8) Function execution ACLs for ERP functions. This is separate from table ACLs.
select
  p.proname as function_name,
  pg_get_function_identity_arguments(p.oid) as identity_arguments,
  p.prosecdef as security_definer,
  coalesce(role.rolname, 'PUBLIC') as grantee,
  acl.privilege_type,
  acl.is_grantable,
  p.proconfig as function_settings
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
cross join lateral aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) acl
left join pg_roles role on role.oid = acl.grantee
where n.nspname = 'public'
  and p.proname like 'erp\_%' escape '\'
  and acl.privilege_type = 'EXECUTE'
order by p.proname, identity_arguments, grantee;

-- 9) Default privileges affecting future objects in public schema.
-- These settings do not retroactively change ACLs on existing objects.
select
  pg_get_userbyid(d.defaclrole) as object_creator_role,
  n.nspname as schema_name,
  d.defaclobjtype as object_type,
  coalesce(grantee.rolname, 'PUBLIC') as grantee,
  acl.privilege_type,
  acl.is_grantable
from pg_default_acl d
left join pg_namespace n on n.oid = d.defaclnamespace
cross join lateral aclexplode(d.defaclacl) acl
left join pg_roles grantee on grantee.oid = acl.grantee
where n.nspname = 'public'
order by object_creator_role, object_type, grantee, privilege_type;

-- 10) Existing IMEI-related function definitions (review text only).
select
  p.proname as function_name,
  pg_get_function_identity_arguments(p.oid) as identity_arguments,
  pg_get_functiondef(p.oid) as function_definition
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname in (
    'erp_check_imei_unique',
    'erp_imei_luhn_valid',
    'erp_link_sold_units_to_sale_line',
    'erp_guard_purchase_unit_link',
    'erp_guard_imei_return',
    'erp_mark_returned_imei_units'
  )
order by p.proname, identity_arguments;

-- End of read-only audit. No DDL/DML statements are present in this file.
