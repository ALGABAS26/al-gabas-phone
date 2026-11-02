-- AL GABAS ERP — Upgrade 27: limit subscription details in SECURITY DEFINER shop profile
-- Apply only in a separate staging project after upgrades 01–26.
-- ERP-only: no storefront/product/RLS changes.
-- Draft only; not executed by this assistant.

BEGIN;

CREATE OR REPLACE FUNCTION public.erp_my_shop_profile()
RETURNS TABLE (
  shop_id uuid,
  shop_name text,
  shop_slug text,
  shop_status text,
  member_role text,
  subscription_status text,
  subscription_expires_at timestamptz
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $func$
  SELECT
    s.id,
    s.name,
    s.slug,
    s.status,
    m.role,
    CASE WHEN m.role IN ('owner','admin') THEN sub.status ELSE NULL END,
    CASE WHEN m.role IN ('owner','admin') THEN sub.expires_at ELSE NULL END
  FROM public.erp_shop_memberships AS m
  JOIN public.erp_shops AS s ON s.id = m.shop_id
  LEFT JOIN public.erp_shop_subscriptions AS sub ON sub.shop_id = s.id
  WHERE m.user_id = auth.uid()
    AND m.status = 'active'
  ORDER BY CASE WHEN m.role = 'owner' THEN 0 ELSE 1 END, s.created_at
  LIMIT 1;
$func$;

REVOKE ALL ON FUNCTION public.erp_my_shop_profile()
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.erp_my_shop_profile()
  TO authenticated;

COMMIT;
