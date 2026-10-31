-- AL GABAS PHONE ERP - Upgrade 03: cash accounts and source-aware Fawry top-ups
-- Run after upgrade-02.sql. Keeps existing balances and movements.
create table if not exists public.erp_cash_accounts (
 id uuid primary key default gen_random_uuid(),
 owner_id uuid not null references auth.users(id) on delete cascade,
 account_code text not null check(account_code in ('drawer','vodafone_cash','instapay')),
 account_name text not null,
 opening_balance numeric(14,2) not null default 0 check(opening_balance>=0),
 created_at timestamptz not null default now(),
 updated_at timestamptz not null default now(),
 unique(owner_id,account_code)
);
alter table public.erp_fawry_daily_closings
 add column if not exists funding_account text not null default 'drawer';
alter table public.erp_fawry_daily_closings
 drop constraint if exists erp_fawry_daily_closings_funding_account_check;
alter table public.erp_fawry_daily_closings
 add constraint erp_fawry_daily_closings_funding_account_check
 check(funding_account in ('drawer','vodafone_cash','instapay'));
alter table public.erp_cash_movements
 add column if not exists account_code text not null default 'drawer';
alter table public.erp_cash_movements
 drop constraint if exists erp_cash_movements_account_code_check;
alter table public.erp_cash_movements
 add constraint erp_cash_movements_account_code_check
 check(account_code in ('drawer','vodafone_cash','instapay'));
alter table public.erp_cash_accounts enable row level security;
drop policy if exists erp_cash_accounts_owner_all on public.erp_cash_accounts;
create policy erp_cash_accounts_owner_all on public.erp_cash_accounts
 for all to authenticated using(owner_id=auth.uid()) with check(owner_id=auth.uid());
grant select,insert,update,delete on public.erp_cash_accounts to authenticated;

-- Create the three ledgers for each owner without overwriting configured opening balances.
create or replace function public.erp_init_cash_accounts() returns void
language plpgsql security invoker set search_path=public as $$
declare v_owner uuid:=auth.uid();
begin
 if v_owner is null then raise exception 'يجب تسجيل الدخول'; end if;
 insert into public.erp_cash_accounts(owner_id,account_code,account_name)
 values (v_owner,'drawer','درج الكاش'),(v_owner,'vodafone_cash','فودافون كاش'),(v_owner,'instapay','إنستا باي')
 on conflict(owner_id,account_code) do nothing;
end $$;
grant execute on function public.erp_init_cash_accounts() to authenticated;

-- Replace the earlier RPC with a version that deducts the selected source account.
drop function if exists public.erp_save_fawry_daily_close(date,numeric,numeric,numeric,numeric,text);
create or replace function public.erp_save_fawry_daily_close(
 p_close_date date,p_opening_balance numeric,p_topup_amount numeric,
 p_closing_balance numeric,p_profit numeric,p_notes text default null,
 p_funding_account text default 'drawer'
) returns uuid language plpgsql security invoker set search_path=public as $$
declare v_owner uuid:=auth.uid(); v_id uuid; v_previous numeric; v_account text;
begin
 if v_owner is null then raise exception 'يجب تسجيل الدخول'; end if;
 if p_funding_account not in ('drawer','vodafone_cash','instapay') then raise exception 'مصدر الشحن غير صحيح'; end if;
 if p_opening_balance<0 or p_topup_amount<0 or p_closing_balance<0 or p_profit<0 then raise exception 'القيم لا يمكن أن تكون سالبة'; end if;
 perform public.erp_init_cash_accounts();
 select closing_balance into v_previous from public.erp_fawry_daily_closings
 where owner_id=v_owner and close_date<p_close_date order by close_date desc limit 1;
 if v_previous is not null and p_opening_balance<>v_previous then
   raise exception 'رصيد افتتاح اليوم يجب أن يساوي رصيد إغلاق آخر تقفيل محفوظ: %',v_previous;
 end if;
 insert into public.erp_fawry_daily_closings(owner_id,close_date,opening_balance,topup_amount,closing_balance,profit,notes,funding_account)
 values(v_owner,p_close_date,p_opening_balance,p_topup_amount,p_closing_balance,p_profit,nullif(trim(p_notes),''),p_funding_account)
 on conflict(owner_id,close_date) do update set
 opening_balance=excluded.opening_balance,topup_amount=excluded.topup_amount,
 closing_balance=excluded.closing_balance,profit=excluded.profit,notes=excluded.notes,funding_account=excluded.funding_account,updated_at=now()
 returning id into v_id;
 if p_topup_amount>0 then
   insert into public.erp_cash_movements(owner_id,movement_date,direction,amount,description,source_type,source_id,account_code)
   values(v_owner,p_close_date,'out',p_topup_amount,'شحن ماكينة فوري من '||
     case p_funding_account when 'drawer' then 'درج الكاش' when 'vodafone_cash' then 'فودافون كاش' else 'إنستا باي' end,
     'fawry_topup',v_id,p_funding_account)
   on conflict(owner_id,source_type,source_id) do update set
     movement_date=excluded.movement_date,direction='out',amount=excluded.amount,
     description=excluded.description,account_code=excluded.account_code;
 else
   delete from public.erp_cash_movements where owner_id=v_owner and source_type='fawry_topup' and source_id=v_id;
 end if;
 return v_id;
end $$;
grant execute on function public.erp_save_fawry_daily_close(date,numeric,numeric,numeric,numeric,text,text) to authenticated;
