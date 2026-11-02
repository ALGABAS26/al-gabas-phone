-- AL GABAS ERP — Multi-Shop ACL inventory (READ ONLY)
-- Target: separate Supabase test project first.
-- This file intentionally contains SELECT statements only.
-- It does NOT repair grants, revoke privileges, alter RLS, or change default privileges.
-- Do not append generic REVOKE ALL statements.
-- The executable ACL migration will be authored only after these outputs,
-- the final RPC signatures, and the approved role matrix have been reviewed.
--
-- Scope: ERP objects only. public.products is deliberately excluded.

-- 1) Table, view, sequence and schema privileges for ERP objects.
SELECT
    table_schema,
    table_name,
    grantee,
    privilege_type,
    is_grantable
FROM information_schema.role_table_grants
WHERE table_schema = 'public'
  AND (
      left(table_name, 4) = 'erp_'
  )
ORDER BY table_name, grantee, privilege_type;

SELECT
    n.nspname AS schema_name,
    r.rolname AS grantee,
    has_schema_privilege(r.oid, n.oid, 'USAGE') AS has_usage,
    has_schema_privilege(r.oid, n.oid, 'CREATE') AS has_create
FROM pg_namespace n
CROSS JOIN pg_roles r
WHERE n.nspname = 'public'
  AND r.rolname IN ('anon','authenticated','service_role','postgres')
ORDER BY r.rolname;

SELECT
    schemaname,
    sequencename,
    grantee,
    privilege_type
FROM information_schema.role_usage_grants
WHERE object_schema = 'public'
  AND left(object_name, 4) = 'erp_'
ORDER BY object_name, grantee, privilege_type;

-- 2) Effective ACL arrays for ERP relations, including objects whose grants
-- may not appear in the information_schema view due to ownership/defaults.
SELECT
    n.nspname AS schema_name,
    c.relname AS object_name,
    c.relkind AS object_kind,
    pg_get_userbyid(c.relowner) AS owner_name,
    c.relacl AS acl
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'public'
  AND left(c.relname, 4) = 'erp_'
  AND c.relkind IN ('r','p','v','m','S','f')
ORDER BY c.relname;

-- 3) Default privileges for the roles that may create ERP objects.
-- Review every row; the object-creating role is important.
SELECT
    d.defaclrole::regrole AS object_creator_role,
    COALESCE(n.nspname, '(all schemas)') AS schema_name,
    d.defaclobjtype AS object_type,
    d.defaclacl AS default_acl
FROM pg_default_acl d
LEFT JOIN pg_namespace n ON n.oid = d.defaclnamespace
WHERE n.nspname = 'public' OR d.defaclnamespace = 0
ORDER BY object_creator_role::text, schema_name, object_type;

-- 4) Exact function signatures, security mode, owner, config and ACL.
-- Trigger functions are included; do not revoke their execution blindly.
SELECT
    p.oid::regprocedure AS exact_signature,
    p.proname AS function_name,
    pg_get_userbyid(p.proowner) AS owner_name,
    p.prosecdef AS security_definer,
    p.proconfig AS function_config,
    p.proacl AS execute_acl,
    pg_get_function_identity_arguments(p.oid) AS identity_arguments
FROM pg_proc p
JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public'
  AND left(p.proname, 4) = 'erp_'
ORDER BY p.proname, exact_signature::text;

-- 5) Expanded EXECUTE grants for ERP functions.
SELECT
    p.oid::regprocedure AS exact_signature,
    CASE
      WHEN x.grantee = 0 THEN 'PUBLIC'
      ELSE r.rolname
    END AS grantee,
    x.privilege_type,
    x.is_grantable
FROM pg_proc p
JOIN pg_namespace n ON n.oid = p.pronamespace
CROSS JOIN LATERAL aclexplode(COALESCE(p.proacl, acldefault('f', p.proowner))) x
LEFT JOIN pg_roles r ON r.oid = x.grantee
WHERE n.nspname = 'public'
  AND left(p.proname, 4) = 'erp_'
ORDER BY p.proname, exact_signature::text, grantee;

-- 6) RLS state and policies for ERP tables.
SELECT
    c.relname AS table_name,
    c.relrowsecurity AS rls_enabled,
    c.relforcerowsecurity AS rls_forced,
    pg_get_userbyid(c.relowner) AS table_owner
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'public'
  AND left(c.relname, 4) = 'erp_'
  AND c.relkind IN ('r','p')
ORDER BY c.relname;

SELECT
    schemaname,
    tablename,
    policyname,
    permissive,
    roles,
    cmd,
    qual,
    with_check
FROM pg_policies
WHERE schemaname = 'public'
  AND left(tablename, 4) = 'erp_'
ORDER BY tablename, policyname;

-- 7) Membership and tenant metadata readiness (read-only).
SELECT
    (SELECT COUNT(*) FROM public.erp_shops) AS shop_count,
    (SELECT COUNT(*) FROM public.erp_shop_memberships) AS membership_count,
    (SELECT COUNT(*) FROM public.erp_shop_memberships WHERE status = 'active') AS active_membership_count;

-- Note:
-- This file assumes upgrades 13 and 14 exist. If a relation is absent,
-- run the metadata checks only after confirming the actual migration state.
-- The next step is to compare these outputs against:
--   accounting/ERP-MULTISHOP-PERMISSION-MATRIX.md
--   accounting/ERP-MULTISHOP-IMPLEMENTATION-PACKAGE.md
-- Do not execute any permission-changing SQL until an exact migration has
-- been reviewed against the captured ACL output and tested in a separate project.
