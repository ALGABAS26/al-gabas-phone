-- AL GABAS ERP — Upgrade 19 staging regression test
-- Run ONLY in a separate Supabase test project after applying upgrade-19.sql.
-- Replace UUID with an existing synthetic auth.users.id in that project.
-- All inserted party rows are rolled back. Never run in production.

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

  -- Case 1: customer with optional contact details and opening balance.
  v_id := public.erp_create_party(
    'customer','RPC staging customer','01000000000','Test address',125.50,'Test notes'
  );
  select count(*) into v_count from public.erp_parties
  where id=v_id and owner_id=v_owner and party_type='customer'
    and name='RPC staging customer' and phone='01000000000'
    and address='Test address' and opening_balance=125.50 and notes='Test notes';
  if v_count<>1 then raise exception 'FAIL: customer fields or owner binding'; end if;

  -- Case 2: supplier with defaults and blank optional fields normalized to NULL.
  v_id := public.erp_create_party('supplier','RPC staging supplier');
  select count(*) into v_count from public.erp_parties
  where id=v_id and owner_id=v_owner and party_type='supplier'
    and name='RPC staging supplier' and phone is null and address is null
    and opening_balance=0 and notes is null;
  if v_count<>1 then raise exception 'FAIL: supplier defaults'; end if;

  v_failed:=false;
  begin perform public.erp_create_party('other','Bad party');
  exception when others then v_failed:=true; end;
  if not v_failed then raise exception 'FAIL: unsupported party type accepted'; end if;

  v_failed:=false;
  begin perform public.erp_create_party('customer','   ');
  exception when others then v_failed:=true; end;
  if not v_failed then raise exception 'FAIL: blank party name accepted'; end if;

  v_failed:=false;
  begin perform public.erp_create_party('customer','Negative balance',null,null,-1,null);
  exception when others then v_failed:=true; end;
  if not v_failed then raise exception 'FAIL: negative opening balance accepted'; end if;

  v_failed:=false;
  begin perform public.erp_create_party('customer','NULL balance',null,null,null,null);
  exception when others then v_failed:=true; end;
  if not v_failed then raise exception 'FAIL: NULL opening balance accepted'; end if;

  v_failed:=false;
  begin perform public.erp_create_party('customer','NaN balance',null,null,'NaN'::numeric,null);
  exception when others then v_failed:=true; end;
  if not v_failed then raise exception 'FAIL: NaN opening balance accepted'; end if;

  perform set_config('request.jwt.claim.sub','',true);
  v_failed:=false;
  begin perform public.erp_create_party('customer','Unauthenticated');
  exception when others then v_failed:=true; end;
  if not v_failed then raise exception 'FAIL: unauthenticated party creation accepted'; end if;

  raise notice 'PASS: customer/supplier creation, defaults, owner binding, validation, and authentication';
end;
$test$;
rollback;
