-- Upgrade 16 Fawry RPC regression test. STAGING ONLY; never run in production.
-- Replace the synthetic user UUID with an existing auth.users.id in a separate test project.
begin;
set local role authenticated;
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000001',true);
do $test$
declare
  v_owner uuid := auth.uid();
  v_id uuid;
  v_count integer;
  v_failed boolean;
  v_ref text := 'RPC-TEST-' || replace(gen_random_uuid()::text,'-','');
begin
  if v_owner is null then raise exception 'Synthetic test user is required'; end if;

  v_id := public.erp_create_fawry_transaction('service',125.50,5,1.25,v_ref,'completed','staging');
  select count(*) into v_count from public.erp_fawry_transactions
   where id=v_id and owner_id=v_owner and type='service' and amount=125.50
   and commission=5 and fee=1.25 and reference=v_ref and status='completed' and notes='staging';
  if v_count<>1 then raise exception 'FAIL: valid transaction or owner binding'; end if;

  v_id := public.erp_create_fawry_transaction('topup',300);
  select count(*) into v_count from public.erp_fawry_transactions
   where id=v_id and owner_id=v_owner and type='topup' and amount=300
   and commission=0 and fee=0 and reference is null and status='completed' and notes is null;
  if v_count<>1 then raise exception 'FAIL: defaults or blank optional values'; end if;

  v_failed:=false;
  begin perform public.erp_create_fawry_transaction('unknown',10,0,0,null,'completed',null);
  exception when others then v_failed:=true; end;
  if not v_failed then raise exception 'FAIL: unsupported type accepted'; end if;

  v_failed:=false;
  begin perform public.erp_create_fawry_transaction('service',0,0,0,null,'completed',null);
  exception when others then v_failed:=true; end;
  if not v_failed then raise exception 'FAIL: zero amount accepted'; end if;

  v_failed:=false;
  begin perform public.erp_create_fawry_transaction('service',-1,0,0,null,'completed',null);
  exception when others then v_failed:=true; end;
  if not v_failed then raise exception 'FAIL: negative amount accepted'; end if;

  v_failed:=false;
  begin perform public.erp_create_fawry_transaction('service',null,0,0,null,'completed',null);
  exception when others then v_failed:=true; end;
  if not v_failed then raise exception 'FAIL: NULL amount accepted'; end if;

  v_failed:=false;
  begin perform public.erp_create_fawry_transaction('service',10,-1,0,null,'completed',null);
  exception when others then v_failed:=true; end;
  if not v_failed then raise exception 'FAIL: negative commission accepted'; end if;

  v_failed:=false;
  begin perform public.erp_create_fawry_transaction('service',10,0,-1,null,'completed',null);
  exception when others then v_failed:=true; end;
  if not v_failed then raise exception 'FAIL: negative fee accepted'; end if;

  v_failed:=false;
  begin perform public.erp_create_fawry_transaction('service',10,0,0,null,'unknown',null);
  exception when others then v_failed:=true; end;
  if not v_failed then raise exception 'FAIL: unsupported status accepted'; end if;

  perform set_config('request.jwt.claim.sub','',true);
  v_failed:=false;
  begin perform public.erp_create_fawry_transaction('service',10,0,0,null,'completed',null);
  exception when others then v_failed:=true; end;
  if not v_failed then raise exception 'FAIL: missing authenticated identity accepted'; end if;

  raise notice 'PASS: valid insert, owner binding, defaults, validation, and authentication';
end;
$test$;
rollback;
