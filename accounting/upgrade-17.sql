-- AL GABAS ERP — Upgrade 17: atomic cash opening-balance RPC
-- Prepared for a separate Supabase staging project only.
-- DO NOT execute against the live Supabase project in this stage.
--
-- Preserves the three existing cash ledgers, owner RLS, and the existing
-- opening-balance guard that blocks edits after movements exist.
-- No cash movement is created or modified by this RPC.

begin;

create or replace function public.erp_save_cash_opening_balances(
  p_drawer_opening_balance numeric,
  p_vodafone_cash_opening_balance numeric,
  p_instapay_opening_balance numeric
)
returns void
language plpgsql
security invoker
set search_path = pg_catalog, public, pg_temp
as $function$
declare
  v_owner uuid := auth.uid();
begin
  if v_owner is null then
    raise exception 'يجب تسجيل الدخول';
  end if;

  if p_drawer_opening_balance is null
     or p_vodafone_cash_opening_balance is null
     or p_instapay_opening_balance is null then
    raise exception 'يجب إدخال الأرصدة الافتتاحية الثلاثة';
  end if;

  if p_drawer_opening_balance < 0
     or p_vodafone_cash_opening_balance < 0
     or p_instapay_opening_balance < 0 then
    raise exception 'الرصيد الافتتاحي لا يمكن أن يكون سالبًا';
  end if;

  if p_drawer_opening_balance::text in ('NaN','Infinity','-Infinity')
     or p_vodafone_cash_opening_balance::text in ('NaN','Infinity','-Infinity')
     or p_instapay_opening_balance::text in ('NaN','Infinity','-Infinity') then
    raise exception 'الأرصدة الافتتاحية يجب أن تكون أرقامًا محدودة وصحيحة';
  end if;

  -- One statement, one transaction: all three accounts are saved together.
  -- The account names/codes are fixed server-side; no owner_id comes from client.
  insert into public.erp_cash_accounts (
    owner_id, account_code, account_name, opening_balance
  )
  values
    (v_owner, 'drawer', 'درج الكاش', p_drawer_opening_balance),
    (v_owner, 'vodafone_cash', 'فودافون كاش', p_vodafone_cash_opening_balance),
    (v_owner, 'instapay', 'إنستا باي', p_instapay_opening_balance)
  on conflict (owner_id, account_code) do update
    set account_name = excluded.account_name,
        opening_balance = excluded.opening_balance,
        updated_at = now();
end;
$function$;

revoke all on function public.erp_save_cash_opening_balances(numeric,numeric,numeric)
  from public, anon;
grant execute on function public.erp_save_cash_opening_balances(numeric,numeric,numeric)
  to authenticated;

commit;
