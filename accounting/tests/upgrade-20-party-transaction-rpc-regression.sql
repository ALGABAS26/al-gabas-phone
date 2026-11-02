-- AL GABAS ERP — Upgrade 20 staging regression test
-- Run ONLY in a separate Supabase test project after applying upgrade-20.sql.
-- Replace UUID with an existing synthetic auth.users.id in that project.
-- All test parties and ledger rows are rolled back. Never run in production.

begin;
set local role authenticated;
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000001',true);

do $test$
declare
  v_owner uuid := auth.uid();
  v_party_id uuid;
  v_tx_id uuid;
  v_count integer;
  v_failed boolean;
begin
  if v_owner is null then raise exception 'Synthetic authenticated user is required'; end if;

  v_party_id := public.erp_create_party('customer','RPC ledger test party');

  -- Case 1: valid increase transaction.
  v_tx_id := public.erp_create_party_transaction(
    v_party_id,current_date,'increase',250,'Amount due from customer'
  );
  select count(*) into v_count
  from public.erp_party_transactions
  where id=v_tx_id and owner_id=v_owner and party_id=v_party_id
    and transaction_date=current_date and direction='increase'
    and amount=250 and description='Amount due from customer';
  if v_count<>1 then raise exception 'FAIL: party ledger transaction or owner binding'; end if;

  -- Case 2: valid decrease transaction.
  v_tx_id := public.erp_create_party_transaction(
    v_party_id,current_date,'decrease',50,'Customer payment'
  );
  select count(*) into v_count
  from public.erp_party_transactions
  where id=v_tx_id and owner_id=v_owner and party_id=v_party_id
    and direction='decrease' and amount=50;
  if v_count<>1 then raise exception 'FAIL: decrease transaction'; end if;

  -- Case 3: missing/foreign party ID must be rejected.
  v_failed:=false;
  begin
    perform public.erp_create_party_transaction(
      'ffffffff-ffff-ffff-ffff-ffffffffffff',current_date,'increase',10,'bad party'
    );
  exception when others then v_failed:=true;
  end;
  if not v_failed then raise exception 'FAIL: nonexistent party ID accepted'; end if;

  v_failed:=false;
  begin perform public.erp_create_party_transaction(v_party_id,null,'increase',10,'bad date');
  exception when others then v_failed:=true; end;
  if not v_failed then raise exception 'FAIL: NULL transaction date accepted'; end if;

  v_failed:=false;
  begin perform public.erp_create_party_transaction(v_party_id,current_date,'invalid',10,'bad direction');
  exception when others then v_failed:=true; end;
  if not v_failed then raise exception 'FAIL: invalid direction accepted'; end if;

  v_failed:=false;
  begin perform public.erp_create_party_transaction(v_party_id,current_date,'increase',0,'zero');
  exception when others then v_failed:=true; end;
  if not v_failed then raise exception 'FAIL: zero amount accepted'; end if;

  v_failed:=false;
  begin perform public.erp_create_party_transaction(v_party_id,current_date,'increase',null,'null');
  exception when others then v_failed:=true; end;
  if not v_failed then raise exception 'FAIL: NULL amount accepted'; end if;

  v_failed:=false;
  begin perform public.erp_create_party_transaction(v_party_id,current_date,'increase',10,'   ');
  exception when others then v_failed:=true; end;
  if not v_failed then raise exception 'FAIL: blank description accepted'; end if;

  perform set_config('request.jwt.claim.sub','',true);
  v_failed:=false;
  begin perform public.erp_create_party_transaction(v_party_id,current_date,'increase',10,'unauth');
  exception when others then v_failed:=true; end;
  if not v_failed then raise exception 'FAIL: unauthenticated transaction accepted'; end if;

  raise notice 'PASS: party ledger posting, parent ownership, validation, and authentication';
end;
$test$;
rollback;
