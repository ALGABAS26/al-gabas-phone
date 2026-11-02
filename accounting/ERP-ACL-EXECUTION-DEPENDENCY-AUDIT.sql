-- AL GABAS ERP — Expanded ACL and execution-dependency evidence
-- READ-ONLY catalog audit. Run in a separate Supabase staging project.
-- This file contains SELECT statements only: no DDL, DML, GRANT, REVOKE,
-- SET ROLE, temporary objects, or changes to database state.
-- Scope is ERP-prefixed objects in public. public.products and storefront
-- objects are deliberately excluded.
--
-- Capture the complete result set before drafting any permission migration.
-- PostgreSQL ACLs are additive: role membership and PUBLIC grants matter.

-- 1) Relevant role membership edges (who inherits whose privileges).
SELECT
    parent.rolname AS granted_role,
    member.rolname AS member_role,
    grantor.rolname AS grantor_role,
    m.admin_option
FROM pg_auth_members m
JOIN pg_roles parent ON parent.oid = m.roleid
JOIN pg_roles member ON member.oid = m.member
JOIN pg_roles grantor ON grantor.oid = m.grantor
WHERE parent.rolname IN ('anon','authenticated','service_role','postgres','supabase_admin')
   OR member.rolname IN ('anon','authenticated','service_role','postgres','supabase_admin')
ORDER BY parent.rolname, member.rolname;

-- 2) ERP relations, owner, RLS, FORCE RLS, and raw ACL.
SELECT
    n.nspname AS schema_name,
    c.relname AS relation_name,
    c.relkind AS relation_kind,
    pg_get_userbyid(c.relowner) AS owner_name,
    c.relrowsecurity AS rls_enabled,
    c.relforcerowsecurity AS force_rls,
    c.relacl AS raw_acl
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'public'
  AND left(c.relname, 4) = 'erp_'
  AND c.relkind IN ('r','p','v','m','S','f')
ORDER BY c.relkind, c.relname;

-- 3) Effective table privileges for browser/service roles.
-- has_table_privilege includes PUBLIC grants and inherited role membership.
SELECT
    c.relname AS relation_name,
    r.rolname AS checked_role,
    has_table_privilege(r.oid, c.oid, 'SELECT') AS can_select,
    has_table_privilege(r.oid, c.oid, 'INSERT') AS can_insert,
    has_table_privilege(r.oid, c.oid, 'UPDATE') AS can_update,
    has_table_privilege(r.oid, c.oid, 'DELETE') AS can_delete,
    has_table_privilege(r.oid, c.oid, 'TRUNCATE') AS can_truncate,
    has_table_privilege(r.oid, c.oid, 'REFERENCES') AS can_references,
    has_table_privilege(r.oid, c.oid, 'TRIGGER') AS can_trigger,
    has_table_privilege(r.oid, c.oid, 'MAINTAIN') AS can_maintain
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
CROSS JOIN pg_roles r
WHERE n.nspname = 'public'
  AND left(c.relname, 4) = 'erp_'
  AND c.relkind IN ('r','p','v','m','f')
  AND r.rolname IN ('anon','authenticated','service_role')
ORDER BY c.relname, r.rolname;

-- 4) Expanded raw relation ACL entries. grantee_oid = 0 means PUBLIC.
SELECT
    c.relname AS relation_name,
    pg_get_userbyid(c.relowner) AS owner_name,
    CASE WHEN x.grantee = 0 THEN 'PUBLIC'
         ELSE COALESCE(grantee_role.rolname, x.grantee::text)
    END AS grantee,
    x.privilege_type,
    x.is_grantable,
    CASE WHEN x.grantor = 0 THEN 'PUBLIC'
         ELSE COALESCE(grantor_role.rolname, x.grantor::text)
    END AS grantor
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
CROSS JOIN LATERAL aclexplode(COALESCE(
    c.relacl,
    acldefault((CASE WHEN c.relkind = 'S' THEN 'S' ELSE 'r' END)::"char", c.relowner)
)) x
LEFT JOIN pg_roles grantee_role ON grantee_role.oid = x.grantee
LEFT JOIN pg_roles grantor_role ON grantor_role.oid = x.grantor
WHERE n.nspname = 'public'
  AND left(c.relname,  4) = 'erp_'
  AND c.relkind IN ('r','p','v','m','S','f')
ORDER BY c.relname, grantee, x.privilege_type;

-- 5) Exact ERP function inventory, execution mode, owner, language and config.
SELECT
    p.oid::regprocedure AS exact_signature,
    p.proname AS function_name,
    pg_get_userbyid(p.proowner) AS owner_name,
    l.lanname AS language_name,
    p.prosecdef AS security_definer,
    p.provolatile AS volatility,
    p.proisstrict AS is_strict,
    p.proconfig AS function_config,
    p.proacl AS raw_execute_acl,
    has_function_privilege('anon', p.oid, 'EXECUTE') AS anon_can_execute,
    has_function_privilege('authenticated', p.oid, 'EXECUTE') AS authenticated_can_execute,
    has_function_privilege('service_role', p.oid, 'EXECUTE') AS service_role_can_execute
FROM pg_proc p
JOIN pg_namespace n ON n.oid = p.pronamespace
JOIN pg_language l ON l.oid = p.prolang
WHERE n.nspname = 'public'
  AND left(p.proname, 4) = 'erp_'
ORDER BY p.proname, exact_signature::text;

-- 6) Expanded function ACL entries. Preserve exact signatures in any future
-- REVOKE/GRANT statement; never revoke functions by name alone.
SELECT
    p.oid::regprocedure AS exact_signature,
    pg_get_userbyid(p.proowner) AS owner_name,
    CASE WHEN x.grantee = 0 THEN 'PUBLIC'
         ELSE COALESCE(grantee_role.rolname, x.grantee::text)
    END AS grantee,
    x.privilege_type,
    x.is_grantable,
    CASE WHEN x.grantor = 0 THEN 'PUBLIC'
         ELSE COALESCE(grantor_role.rolname, x.grantor::text)
    END AS grantor
FROM pg_proc p
JOIN pg_namespace n ON n.oid = p.pronamespace
CROSS JOIN LATERAL aclexplode(COALESCE(p.proacl, acldefault('f', p.proowner))) x
LEFT JOIN pg_roles grantee_role ON grantee_role.oid = x.grantee
LEFT JOIN pg_roles grantor_role ON grantor_role.oid = x.grantor
WHERE n.nspname = 'public'
  AND left(p.proname, 4) = 'erp_'
ORDER BY p.proname, exact_signature::text, grantee;

-- 7) Trigger-to-function dependency map. Trigger functions are not ordinary
-- client RPCs; do not revoke their EXECUTE privileges indiscriminately.
SELECT
    tbl.relname AS table_name,
    trg.tgname AS trigger_name,
    trg.tgenabled AS trigger_enabled,
    pg_get_triggerdef(trg.oid, true) AS trigger_definition,
    fn.oid::regprocedure AS trigger_function_signature,
    pg_get_userbyid(fn.proowner) AS function_owner,
    fn.prosecdef AS function_is_security_definer,
    fn.proconfig AS function_config
FROM pg_trigger trg
JOIN pg_class tbl ON tbl.oid = trg.tgrelid
JOIN pg_namespace ns ON ns.oid = tbl.relnamespace
JOIN pg_proc fn ON fn.oid = trg.tgfoid
WHERE NOT trg.tgisinternal
  AND ns.nspname = 'public'
  AND left(tbl.relname, 4) = 'erp_'
ORDER BY tbl.relname, trg.tgname;

-- 8) ERP sequence ownership and defaults that consume sequences.
SELECT
    seq.relname AS sequence_name,
    pg_get_userbyid(seq.relowner) AS sequence_owner,
    tbl.relname AS owning_table,
    att.attname AS owning_column,
    dep.deptype AS dependency_type,
    seq.relacl AS raw_sequence_acl,
    has_sequence_privilege('anon', seq.oid, 'USAGE') AS anon_can_use,
    has_sequence_privilege('authenticated', seq.oid, 'USAGE') AS authenticated_can_use,
    has_sequence_privilege('service_role', seq.oid, 'USAGE') AS service_role_can_use
FROM pg_class seq
JOIN pg_namespace ns ON ns.oid = seq.relnamespace
LEFT JOIN pg_depend dep
       ON dep.classid = 'pg_class'::regclass
      AND dep.objid = seq.oid
      AND dep.refclassid = 'pg_class'::regclass
      AND dep.deptype IN ('a','i')
LEFT JOIN pg_class tbl ON tbl.oid = dep.refobjid
LEFT JOIN pg_attribute att
       ON att.attrelid = dep.refobjid
      AND att.attnum = dep.refobjsubid
WHERE ns.nspname = 'public'
  AND left(seq.relname, 4) = 'erp_'
  AND seq.relkind = 'S'
ORDER BY seq.relname;

-- 9) Column defaults that call nextval, including defaults whose sequence
-- name may not share the erp_ prefix.
SELECT
    tbl.relname AS table_name,
    att.attname AS column_name,
    pg_get_expr(def.adbin, def.adrelid) AS column_default
FROM pg_attrdef def
JOIN pg_class tbl ON tbl.oid = def.adrelid
JOIN pg_namespace ns ON ns.oid = tbl.relnamespace
JOIN pg_attribute att
  ON att.attrelid = def.adrelid
 AND att.attnum = def.adnum
WHERE ns.nspname = 'public'
  AND left(tbl.relname, 4) = 'erp_'
  AND pg_get_expr(def.adbin, def.adrelid) ILIKE '%nextval%'
ORDER BY tbl.relname, att.attnum;

-- 10) Default ACLs by creator role, schema, and object type. These are
-- independent of existing-object ACLs and can affect future public objects.
SELECT
    d.defaclrole::regrole AS object_creator_role,
    COALESCE(ns.nspname, '(all schemas)') AS schema_name,
    d.defaclobjtype AS object_type,
    d.defaclacl AS default_acl
FROM pg_default_acl d
LEFT JOIN pg_namespace ns ON ns.oid = d.defaclnamespace
WHERE ns.nspname = 'public' OR d.defaclnamespace = 0
ORDER BY object_creator_role::text, schema_name, object_type;

-- 11) RLS flags and policies for ERP tables.
SELECT
    c.relname AS table_name,
    c.relrowsecurity AS rls_enabled,
    c.relforcerowsecurity AS force_rls,
    pg_get_userbyid(c.relowner) AS table_owner
FROM pg_class c
JOIN pg_namespace ns ON ns.oid = c.relnamespace
WHERE ns.nspname = 'public'
  AND left(c.relname, 4) = 'erp_'
  AND c.relkind IN ('r','p')
ORDER BY c.relname;

SELECT
    schemaname, tablename, policyname, permissive, roles, cmd, qual, with_check
FROM pg_policies
WHERE schemaname = 'public'
  AND left(tablename, 4) = 'erp_'
ORDER BY tablename, policyname;

-- 12) Schema privileges relevant to the browser roles.
SELECT
    r.rolname AS checked_role,
    has_schema_privilege(r.oid, 'public', 'USAGE') AS can_use_public,
    has_schema_privilege(r.oid, 'public', 'CREATE') AS can_create_in_public
FROM pg_roles r
WHERE r.rolname IN ('anon','authenticated','service_role','postgres','supabase_admin')
ORDER BY r.rolname;

-- Review checklist:
-- * Compare effective privileges with raw ACL entries and role membership.
-- * Classify each ERP function as client RPC, trigger function, or internal helper.
-- * Check function owner, SECURITY DEFINER, search_path, and exact EXECUTE grants.
-- * Identify sequence use from defaults and actual invoker write paths.
-- * Keep existing-object ACLs separate from default ACLs.
-- * Do not alter public-schema defaults without assessing non-ERP objects.
-- * Do not execute a REVOKE migration until staging regressions pass.
