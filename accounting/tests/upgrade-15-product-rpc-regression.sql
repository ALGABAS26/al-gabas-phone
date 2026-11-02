-- AL GABAS ERP — Upgrade 15 staging regression test
-- Run ONLY in a separate Supabase test project after applying upgrade-15.sql.
-- Uses a synthetic authenticated test user and rolls all test rows back.
-- Replace the UUID below with an existing synthetic auth.users.id in that project.
-- Do not run this file in production.

begin;

set local role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000001', true);

do $test$
declare
  v_owner uuid := auth.uid();
  v_plain_id uuid;
  v_imei_id uuid;
  v_duplicate_barcode text := 'TEST-DUP-' || replace(gen_random_uuid()::text,'-','');
  v_imei_barcode text := 'TEST-IMEI-' || replace(gen_random_uuid()::text,'-','');
  v_plain_barcode text := 'TEST-PLAIN-' || replace(gen_random_uuid()::text,'-','');
  v_unit_count integer;
  v_product_count integer;
  v_failed boolean;
begin
  if v_owner is null then
    raise exception 'Test setup failed: synthetic authenticated user UUID was not accepted';
  end if;

  -- Case 1: ordinary product, no IMEI.
  v_plain_id := public.erp_create_product_with_optional_imei(
    'RPC test plain product', 'test', 'new', 100, 150, 3,
    v_plain_barcode, null, null
  );

  select count(*) into v_unit_count
  from public.erp_product_units
  where owner_id=v_owner and product_id=v_plain_id;
  if v_unit_count <> 0 then
    raise exception 'FAIL: non-IMEI product unexpectedly created a serial unit';
  end if;

  -- Case 2: product and one valid IMEI unit are created together.
  v_imei_id := public.erp_create_product_with_optional_imei(
    'RPC test IMEI product', 'test', 'new', 200, 250, 1,
    v_imei_barcode, '490154203237518', null
  );

  select count(*) into v_unit_count
  from public.erp_product_units
  where owner_id=v_owner and product_id=v_imei_id
    and imei1='490154203237518' and status='in_stock';
  if v_unit_count <> 1 then
    raise exception 'FAIL: valid IMEI unit was not created exactly once';
  end if;

  -- Case 3: invalid Luhn IMEI must fail and leave no product row.
  v_failed := false;
  begin
    perform public.erp_create_product_with_optional_imei(
      'RPC test invalid IMEI', 'test', 'new', 100, 150, 1,
      'TEST-BAD-' || replace(gen_random_uuid()::text,'-',''),
      '490154203237519', null
    );
  exception when others then
    v_failed := true;
  end;
  if not v_failed then
    raise exception 'FAIL: invalid Luhn IMEI was accepted';
  end if;

  -- Case 4: duplicate IMEI trigger failure must roll back the new product too.
  v_failed := false;
  begin
    perform public.erp_create_product_with_optional_imei(
      'RPC test duplicate IMEI', 'test', 'new', 100, 150, 1,
      v_duplicate_barcode, '490154203237518', null
    );
  exception when others then
    v_failed := true;
  end;
  if not v_failed then
    raise exception 'FAIL: duplicate IMEI was accepted';
  end if;

  select count(*) into v_product_count
  from public.erp_products
  where owner_id=v_owner and barcode=v_duplicate_barcode;
  if v_product_count <> 0 then
    raise exception 'FAIL: product row remained after serial-unit insert failed; atomic rollback broken';
  end if;

  -- Case 5: unauthenticated invocation must be rejected.
  perform set_config('request.jwt.claim.sub', '', true);
  v_failed := false;
  begin
    perform public.erp_create_product_with_optional_imei(
      'RPC test unauthenticated', 'test', 'new', 100, 150, 1,
      'TEST-UNAUTH-' || replace(gen_random_uuid()::text,'-',''),
      null, null
    );
  exception when others then
    v_failed := true;
  end;
  if not v_failed then
    raise exception 'FAIL: unauthenticated RPC call was accepted';
  end if;
  perform set_config('request.jwt.claim.sub', v_owner::text, true);

  raise notice 'PASS: product RPC basic, IMEI, validation, duplicate, atomic rollback and authentication checks';
end;
$test$;

rollback;
