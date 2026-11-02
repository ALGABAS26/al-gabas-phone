-- AL GABAS ERP — SELECT-only owner/FK preflight audit
-- Run only in a separate staging project first.
-- This script does not read or modify public.products, storefront objects, or live data.
-- It performs catalog reads and emits per-FK SELECT statements; it does not execute
-- generated SQL. Review the output, then run the generated SELECTs individually.
--
-- Purpose:
--   1) Find ERP foreign keys where both child and parent have owner_id but the FK
--      does not include owner_id.
--   2) Generate orphan and cross-owner row-count checks for each candidate FK.
--
-- A candidate is not automatically a defect: nullable relationships, legacy design,
-- and application invariants must be reviewed before proposing any constraint change.
-- Do not add composite constraints until all generated checks are clean and duplicates
-- on the proposed parent keys have also been checked.

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
    con.conkey,
    con.confkey,
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
    AND child.relname LIKE 'erp\_%' ESCAPE '\\'
    AND parent.relname LIKE 'erp\_%' ESCAPE '\\'
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
    con.condeferrable, con.condeferred, con.conkey, con.confkey
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

-- Additional duplicate-key preflight:
-- For every proposed composite parent key (id, owner_id), verify that it is unique
-- before creating a UNIQUE constraint/index. The normal PK on id usually guarantees
-- this, but inspect actual deployed constraints rather than assuming migration parity.
SELECT
  n.nspname AS schema_name,
  c.relname AS erp_table,
  bool_or(a.attname = 'id') AS has_id,
  bool_or(a.attname = 'owner_id') AS has_owner_id,
  string_agg(format('%I', a.attname), ', ' ORDER BY a.attnum) AS visible_columns
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
JOIN pg_attribute a ON a.attrelid = c.oid
WHERE n.nspname = 'public'
  AND c.relkind IN ('r','p')
  AND c.relname LIKE 'erp\_%' ESCAPE '\\'
  AND a.attnum > 0
  AND NOT a.attisdropped
GROUP BY n.nspname, c.relname
HAVING bool_or(a.attname = 'id') AND bool_or(a.attname = 'owner_id')
ORDER BY c.relname;
