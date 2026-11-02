-- AL GABAS ERP — Upgrade 17 staging regression test
-- Run ONLY in a separate Supabase test project after applying upgrade-17.sql.
-- Replace UUID with an existing synthetic auth.users.id in that project.
-- Requires a synthetic user with no cash movements; all changes are rolled back.
-- Never run this test in production.

begin;
set local role authenticated;
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000001',true);

do $test$
declare
  v_owner uuid := auth.uid();
  v_count integer;
  v_failed boolean;
begin
  if v_owner is null then
    raise exception 'Test setup failed: synthetic authenticated user UUID was not accepted';
  end if;

  perform public.erp_init_cash_accounts();

  if exists (
    select 1 from public.erp_cash_movements where owner_id=v_owner
  ) then
    raise exception 'Test setup requires a synthetic user with no cash movements';
  end if;

  -- Case 1: all three opening balances are saved atomically.
  perform public.erp_save_cash_opening_balances(1000, 250, 75.50);

  select count(*) into v_count
  from public.erp_cash_accounts
  where owner_id=v_owner
    and (
      (account_code='drawer' and account_name='درج الكاش' and opening_balance=1000)
      or (account_code='vodafone_cash' and account_name='فودافون كاش' and opening_balance=250)
      or (account_code='instapay' and account_name='إنستا باي' and opening_balance=75.50)
    );
  if v_count <> 3 then
    raise exception 'FAIL: expected all three owner cash accounts to be saved';
  end if;

  -- Case 2: negative balance rejected.
  v_failed := false;
  begin
    perform public.erp_save_cash_opening_balances(1000, -1, 75.50);
  exception when others then v_failed := true;
  end;
  if not v_failed then raise exception 'FAIL: negative opening balance was accepted'; end if;

  -- Case 3: NULL in any required balance rejected.
  v_failed := false;
  begin
    perform public.erp_save_cash_opening_balances(1000, null, 75.50);
  exception when others then v_failed := true;
  end;
  if not v_failed then raise exception 'FAIL: NULL opening balance was accepted'; end if;

  -- Case 4: special numeric values rejected.
  v_failed := false;
  begin
    perform public.erp_save_cash_opening_balances('NaN'::numeric, 250, 75.50);
  exception when others then v_failed := true;
  end;
  if not v_failed then raise exception 'FAIL: NaN opening balance was accepted'; end if;

  -- Case 5: unauthenticated call rejected.
  perform set_config('request.jwt.claim.sub','',true);
  v_failed := false;
  begin
    perform public.erp_save_cash_opening_balances(1000, 250, 75.50);
  exception when others then v_failed := true;
  end;
  if not v_failed then raise exception 'FAIL: unauthenticated RPC call was accepted'; end if;

  raise notice 'PASS: atomic three-account upsert, validation, and authentication checks';
end;
$test$;

rollback;
