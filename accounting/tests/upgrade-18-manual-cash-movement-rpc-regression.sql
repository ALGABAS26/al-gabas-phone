-- AL GABAS ERP — Upgrade 18 staging regression test
-- Run ONLY in a separate Supabase test project after applying upgrade-18.sql.
-- Requires upgrades 03, 10, and 17 plus an existing synthetic auth.users.id.
-- The synthetic user must have no cash movements. All changes are rolled back.
-- Never run this test in production.

begin;
set local role authenticated;
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000001',true);

do $test$
declare
  v_owner uuid := auth.uid();
  v_out_id uuid;
  v_in_id uuid;
  v_count integer;
  v_balance numeric;
  v_failed boolean;
begin
  if v_owner is null then raise exception 'Synthetic authenticated user is required'; end if;
  perform public.erp_init_cash_accounts();

  if exists(select 1 from public.erp_cash_movements where owner_id=v_owner) then
    raise exception 'Test setup requires a synthetic user with no cash movements';
  end if;

  perform public.erp_save_cash_opening_balances(1000,1000,1000);

  -- Case 1: authenticated manual outflow is created with server-owned source metadata.
  v_out_id := public.erp_create_manual_cash_movement(
    current_date,'out',200,'Staging manual cash outflow','drawer'
  );
  select count(*) into v_count
  from public.erp_cash_movements
  where id=v_out_id and owner_id=v_owner and movement_date=current_date
    and direction='out' and amount=200 and description='Staging manual cash outflow'
    and source_type='manual' and account_code='drawer';
  if v_count<>1 then raise exception 'FAIL: manual outflow fields or owner binding'; end if;

  -- Case 2: inflow updates the same account ledger through the existing trigger.
  v_in_id := public.erp_create_manual_cash_movement(
    current_date,'in',50,'Staging manual cash inflow','drawer'
  );
  select coalesce(c.opening_balance,0)+coalesce(sum(
    case when m.direction='in' then m.amount else -m.amount end
  ),0) into v_balance
  from public.erp_cash_accounts c
  left join public.erp_cash_movements m
    on m.owner_id=c.owner_id and m.account_code=c.account_code
  where c.owner_id=v_owner and c.account_code='drawer'
  group by c.opening_balance;
  if v_balance<>850 then raise exception 'FAIL: expected drawer balance 850, got %',v_balance; end if;

  -- Case 3: insufficient outflow is rejected by the existing DB balance trigger.
  v_failed:=false;
  begin
    perform public.erp_create_manual_cash_movement(
      current_date,'out',1000,'Must be rejected','drawer'
    );
  exception when others then v_failed:=true;
  end;
  if not v_failed then raise exception 'FAIL: insufficient cash outflow was accepted'; end if;

  -- Case 4: invalid direction, amount, account, and blank description are rejected.
  v_failed:=false;
  begin perform public.erp_create_manual_cash_movement(current_date,'sideways',10,'x','drawer');
  exception when others then v_failed:=true; end;
  if not v_failed then raise exception 'FAIL: invalid direction accepted'; end if;

  v_failed:=false;
  begin perform public.erp_create_manual_cash_movement(current_date,'in',0,'x','drawer');
  exception when others then v_failed:=true; end;
  if not v_failed then raise exception 'FAIL: zero amount accepted'; end if;

  v_failed:=false;
  begin perform public.erp_create_manual_cash_movement(current_date,'in',10,'x','unknown');
  exception when others then v_failed:=true; end;
  if not v_failed then raise exception 'FAIL: unknown cash account accepted'; end if;

  v_failed:=false;
  begin perform public.erp_create_manual_cash_movement(current_date,'in',10,'   ','drawer');
  exception when others then v_failed:=true; end;
  if not v_failed then raise exception 'FAIL: blank description accepted'; end if;

  -- Case 5: unauthenticated call is rejected.
  perform set_config('request.jwt.claim.sub','',true);
  v_failed:=false;
  begin perform public.erp_create_manual_cash_movement(current_date,'in',10,'unauth','drawer');
  exception when others then v_failed:=true; end;
  if not v_failed then raise exception 'FAIL: unauthenticated call accepted'; end if;

  raise notice 'PASS: manual cash movement, owner binding, ledger balance guard, validation, and authentication';
end;
$test$;
rollback;
