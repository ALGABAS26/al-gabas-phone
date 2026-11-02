-- AL GABAS ERP — SELECT-only owner/FK preflight audit
-- Run in a separate staging project first.
-- Catalog-only discovery; does not alter data, schema, grants, or storefront objects.
-- public.products is excluded because only public.erp_% relations are considered.
-- The first query finds FKs between ERP tables that both have owner_id but whose
-- FK column mapping omits owner_id. It emits SELECT statements; it does not execute
-- the generated statements. Review and run those statements individually.
--
-- A candidate is not automatically a defect. Review nullable relationships,
-- intentional cross-table references, legacy invariants, and actual application use.
-- Do not add composite constraints until orphan/cross-owner checks and duplicate-key
-- checks have been reviewed against the deployed staging schema.

WITH fk_columns AS (
  SELECT
    con.oid AS constraint_oid,
    con.conname,
    child_ns.nspname AS child_schema,
    child.relname AS child_table,
    parent_ns.nspname AS parent_schema,
    parent.relname AS parent_table,
    con.convalidated,
    con.condeferrable,
    con.condeferred,
    bool_or(child_att.attname = 'owner_id') AS child_fk_has_owner,
    bool_or(parent_att.attname = 'owner_id') AS parent_fk_has_owner,
    string_agg(
      format('c.%I = p.%I', child_att.attname, parent_att.attname),
      ' AND ' ORDER BY key_col.ordinality
    ) AS join_predicate,
    string_agg(
      format('c.%I IS NOT NULL', child_att.attname),
      ' AND ' ORDER BY key_col.ordinality
    ) AS child_fk_nonnull_predicate,
    (array_agg(parent_att.attname ORDER BY key_col.ordinality))[1]
      AS first_parent_key_column
  FROM pg_constraint con
  JOIN pg_class child ON child.oid = con.conrelid
  JOIN pg_namespace child_ns ON child_ns.oid = child.relnamespace
  JOIN pg_class parent ON parent.oid = con.confrelid
  JOIN pg_namespace parent_ns ON parent_ns.oid = parent.relnamespace
  JOIN LATERAL unnest(con.conkey, con.confkey)
    WITH ORDINALITY AS key_col(child_attnum, parent_attnum, ordinality) ON true
  JOIN pg_attribute child_att
    ON child_att.attrelid = child.oid
   AND child_att.attnum = key_col.child_attnum
   AND NOT child_att.attisdropped
  JOIN pg_attribute parent_att
    ON parent_att.attrelid = parent.oid
   AND parent_att.attnum = key_col.parent_attnum
   AND NOT parent_att.attisdropped
  WHERE con.contype = 'f'
    AND child_ns.nspname = 'public'
    AND parent_ns.nspname = 'public'
    AND left(child.relname, 4) = 'erp_'
    AND left(parent.relname, 4) = 'erp_'
    AND EXISTS (
      SELECT 1 FROM pg_attribute a
      WHERE a.attrelid = child.oid AND a.attname = 'owner_id'
        AND a.attnum > 0 AND NOT a.attisdropped
    )
    AND EXISTS (
      SELECT 1 FROM pg_attribute a
      WHERE a.attrelid = parent.oid AND a.attname = 'owner_id'
        AND a.attnum > 0 AND NOT a.attisdropped
    )
  GROUP BY
    con.oid, con.conname, child_ns.nspname, child.relname,
    parent_ns.nspname, parent.relname, con.convalidated,
    con.condeferrable, con.condeferred
)
SELECT
  constraint_oid,
  conname AS foreign_key_name,
  format('%I.%I', child_schema, child_table) AS child_relation,
  format('%I.%I', parent_schema, parent_table) AS parent_relation,
  convalidated AS is_validated,
  condeferrable AS is_deferrable,
  condeferred AS initially_deferred,
  child_fk_has_owner,
  parent_fk_has_owner,
  CASE
    WHEN child_fk_has_owner AND parent_fk_has_owner
      THEN 'FK includes owner_id'
    ELSE 'CANDIDATE: FK omits owner_id'
  END AS owner_fk_assessment,
  CASE
    WHEN NOT child_fk_has_owner OR NOT parent_fk_has_owner THEN
      format(
        '-- Orphan check for %I.%I -> %I.%I (%I)\n'
        || 'SELECT count(*) AS orphan_rows FROM %I.%I c '
        || 'LEFT JOIN %I.%I p ON %s '
        || 'WHERE (%s) AND p.%I IS NULL;\n'
        || '-- Cross-owner check for the same FK\n'
        || 'SELECT count(*) AS cross_owner_rows FROM %I.%I c '
        || 'JOIN %I.%I p ON %s '
        || 'WHERE (%s) AND c.owner_id IS DISTINCT FROM p.owner_id;',
        child_schema, child_table, parent_schema, parent_table, conname,
        child_schema, child_table, parent_schema, parent_table,
        join_predicate, child_fk_nonnull_predicate, first_parent_key_column,
        child_schema, child_table, parent_schema, parent_table,
        join_predicate, child_fk_nonnull_predicate
      )
    ELSE NULL
  END AS generated_select_only_checks
FROM fk_columns
ORDER BY child_table, conname;

-- Existing primary/unique keys on ERP tables. Use this inventory to confirm whether
-- a proposed parent key is already unique before considering an owner-aware FK.
SELECT
  ns.nspname AS schema_name,
  tbl.relname AS erp_table,
  con.conname AS key_name,
  CASE con.contype WHEN 'p' THEN 'PRIMARY KEY' ELSE 'UNIQUE' END AS key_type,
  pg_get_constraintdef(con.oid, true) AS key_definition,
  bool_or(att.attname = 'owner_id') AS key_includes_owner_id
FROM pg_constraint con
JOIN pg_class tbl ON tbl.oid = con.conrelid
JOIN pg_namespace ns ON ns.oid = tbl.relnamespace
JOIN LATERAL unnest(con.conkey) WITH ORDINALITY AS key_col(attnum, ordinality) ON true
JOIN pg_attribute att
  ON att.attrelid = tbl.oid
 AND att.attnum = key_col.attnum
 AND NOT att.attisdropped
WHERE con.contype IN ('p','u')
  AND ns.nspname = 'public'
  AND left(tbl.relname, 4) = 'erp_'
GROUP BY ns.nspname, tbl.relname, con.conname, con.contype, con.oid
ORDER BY tbl.relname, con.conname;
