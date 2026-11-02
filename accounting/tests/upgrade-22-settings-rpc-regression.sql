-- AL GABAS ERP — Upgrade 22 staging regression test
-- Run ONLY in a separate Supabase test project after applying upgrade-22.sql.
-- Replace UUID with an existing synthetic auth.users.id in that project.
-- Changes are rolled back. Never run in production.

begin;
set local role authenticated;
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000001',true);

do $test$
declare
  v_owner uuid := auth.uid();
  v_id uuid;
  v_count integer;
  v_failed boolean;
begin
  if v_owner is null then raise exception 'Synthetic authenticated user is required'; end if;

  -- Case 1: insert settings with all fields.
  v_id := public.erp_save_shop_settings(
    'محل الاختبار','TEST SHOP','01000000000','Test address','EGP','TST','Test invoice note'
  );
  select count(*) into v_count from public.erp_shop_settings
  where id=v_id and owner_id=v_owner and shop_name='محل الاختبار'
    and shop_name_en='TEST SHOP' and phone='01000000000'
    and address='Test address' and currency='EGP'
    and invoice_prefix='TST' and invoice_note='Test invoice note';
  if v_count<>1 then raise exception 'FAIL: settings insert or owner binding'; end if;

  -- Case 2: upsert updates the same owner's row and applies defaults.
  v_id := public.erp_save_shop_settings('اسم جديد','NEW NAME');
  select count(*) into v_count from public.erp_shop_settings
  where id=v_id and owner_id=v_owner and shop_name='اسم جديد'
    and shop_name_en='NEW NAME' and phone is null and address is null
    and currency='EGP' and invoice_prefix='AGP' and invoice_note is null;
  if v_count<>1 then raise exception 'FAIL: settings upsert/default behavior'; end if;

  v_failed:=false;
  begin perform public.erp_save_shop_settings('   ','SHOP');
  exception when others then v_failed:=true; end;
  if not v_failed then raise exception 'FAIL: blank Arabic shop name accepted'; end if;

  v_failed:=false;
  begin perform public.erp_save_shop_settings('محل','   ');
  exception when others then v_failed:=true; end;
  if not v_failed then raise exception 'FAIL: blank English shop name accepted'; end if;

  v_failed:=false;
  begin perform public.erp_save_shop_settings('محل','SHOP',null,null,'USD');
  exception when others then v_failed:=true; end;
  if not v_failed then raise exception 'FAIL: unsupported currency accepted'; end if;

  perform set_config('request.jwt.claim.sub','',true);
  v_failed:=false;
  begin perform public.erp_save_shop_settings('محل','SHOP');
  exception when others then v_failed:=true; end;
  if not v_failed then raise exception 'FAIL: unauthenticated settings write accepted'; end if;

  raise notice 'PASS: settings insert/upsert, defaults, validation, and authentication';
end;
$test$;
rollback;
