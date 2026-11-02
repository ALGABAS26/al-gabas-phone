-- AL GABAS ERP — Upgrade 27 staging regression test
-- Requires an existing synthetic auth.users row with the UUID below.
-- Run only in a separate staging project after upgrade-27.sql.
-- All fixture rows are rolled back. Never run in production.

BEGIN;

DO $fixture$
DECLARE
  v_user uuid := '00000000-0000-0000-0000-000000000001';
  v_shop uuid;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM auth.users WHERE id=v_user) THEN
    RAISE EXCEPTION 'Create the synthetic auth user fixture before running this test';
  END IF;

  INSERT INTO public.erp_shops(name,slug,created_by)
  VALUES ('ACL Profile Test','acl-profile-'||replace(gen_random_uuid()::text,'-',''),v_user)
  RETURNING id INTO v_shop;

  INSERT INTO public.erp_shop_memberships(shop_id,user_id,role,status)
  VALUES (v_shop,v_user,'viewer','active');

  INSERT INTO public.erp_shop_subscriptions(shop_id,plan_code,status,expires_at)
  VALUES (v_shop,'test-plan','active',now()+interval '30 days');

  PERFORM set_config('test.erp_shop_profile_shop_id',v_shop::text,true);
END;
$fixture$;

SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub',
  '00000000-0000-0000-0000-000000000001',true);

DO $viewer$
DECLARE
  v_role text;
  v_subscription text;
  v_expires timestamptz;
BEGIN
  SELECT member_role,subscription_status,subscription_expires_at
    INTO v_role,v_subscription,v_expires
  FROM public.erp_my_shop_profile()
  WHERE shop_id=current_setting('test.erp_shop_profile_shop_id')::uuid;

  IF v_role IS DISTINCT FROM 'viewer'
     OR v_subscription IS NOT NULL
     OR v_expires IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL: viewer can read subscription metadata through SECURITY DEFINER profile';
  END IF;
END;
$viewer$;

RESET ROLE;
UPDATE public.erp_shop_memberships
SET role='admin'
WHERE shop_id=current_setting('test.erp_shop_profile_shop_id')::uuid
  AND user_id='00000000-0000-0000-0000-000000000001';

SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub',
  '00000000-0000-0000-0000-000000000001',true);

DO $admin$
DECLARE
  v_role text;
  v_subscription text;
  v_expires timestamptz;
BEGIN
  SELECT member_role,subscription_status,subscription_expires_at
    INTO v_role,v_subscription,v_expires
  FROM public.erp_my_shop_profile()
  WHERE shop_id=current_setting('test.erp_shop_profile_shop_id')::uuid;

  IF v_role IS DISTINCT FROM 'admin'
     OR v_subscription IS DISTINCT FROM 'active'
     OR v_expires IS NULL THEN
    RAISE EXCEPTION 'FAIL: admin cannot read expected subscription metadata';
  END IF;
END;
$admin$;

ROLLBACK;

-- Also verify EXECUTE is granted to authenticated and not PUBLIC/anon using
-- the ACL dependency audit; this script does not substitute for that audit.
