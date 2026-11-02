-- AL GABAS STORE ERP - Upgrade 09: safe transfers between cash accounts
-- Run after upgrade-08.sql. ERP-only tables; storefront is untouched.
create table if not exists public.erp_cash_transfers (
 id uuid primary key default gen_random_uuid(),
 owner_id uuid not null references auth.users(id) on delete cascade,
 transfer_date date not null default current_date,
 from_account text not null check(from_account in ('drawer','vodafone_cash','instapay')),
 to_account text not null check(to_account in ('drawer','vodafone_cash','instapay')),
 amount numeric(14,2) not null check(amount>0),
 notes text,
 created_at timestamptz not null default now(),
 check(from_account<>to_account)
);
create index if not exists erp_cash_transfers_owner_date_idx on public.erp_cash_transfers(owner_id,transfer_date desc);
alter table public.erp_cash_transfers enable row level security;
drop policy if exists erp_cash_transfers_owner_all on public.erp_cash_transfers;
create policy erp_cash_transfers_owner_all on public.erp_cash_transfers for all to authenticated using(owner_id=auth.uid()) with check(owner_id=auth.uid());
grant select,insert on public.erp_cash_transfers to authenticated;

create or replace function public.erp_transfer_cash(
 p_transfer_date date,p_from_account text,p_to_account text,p_amount numeric,p_notes text default null
) returns uuid language plpgsql security invoker set search_path=public as $$
declare
 v_owner uuid:=auth.uid(); v_id uuid; v_from_balance numeric(14,2); v_from_opening numeric(14,2);
begin
 if v_owner is null then raise exception 'يجب تسجيل الدخول'; end if;
 if p_from_account not in ('drawer','vodafone_cash','instapay') or p_to_account not in ('drawer','vodafone_cash','instapay') then raise exception 'اختر حسابي تحويل صحيحين'; end if;
 if p_from_account=p_to_account then raise exception 'لا يمكن التحويل إلى نفس الحساب'; end if;
 if p_amount is null or p_amount<=0 then raise exception 'مبلغ التحويل يجب أن يكون أكبر من صفر'; end if;
 perform public.erp_init_cash_accounts();
 -- Serialize operations touching either account, in stable order.
 perform 1 from public.erp_cash_accounts
 where owner_id=v_owner and account_code in (p_from_account,p_to_account)
 order by account_code for update;
 select opening_balance into v_from_opening from public.erp_cash_accounts where owner_id=v_owner and account_code=p_from_account;
 select coalesce(sum(case when direction='in' then amount else -amount end),0)
 into v_from_balance from public.erp_cash_movements where owner_id=v_owner and account_code=p_from_account;
 v_from_balance:=coalesce(v_from_opening,0)+v_from_balance;
 if p_amount>v_from_balance then raise exception 'الرصيد غير كافٍ في الحساب المحدد. الرصيد المتاح: %',v_from_balance; end if;
 insert into public.erp_cash_transfers(owner_id,transfer_date,from_account,to_account,amount,notes)
 values(v_owner,coalesce(p_transfer_date,current_date),p_from_account,p_to_account,p_amount,nullif(trim(p_notes),'')) returning id into v_id;
 insert into public.erp_cash_movements(owner_id,movement_date,direction,amount,description,source_type,source_id,account_code)
 values
 (v_owner,coalesce(p_transfer_date,current_date),'out',p_amount,'تحويل إلى '||case p_to_account when 'drawer' then 'درج الكاش' when 'vodafone_cash' then 'فودافون كاش' else 'إنستا باي' end,'cash_transfer_out',v_id,p_from_account),
 (v_owner,coalesce(p_transfer_date,current_date),'in',p_amount,'تحويل من '||case p_from_account when 'drawer' then 'درج الكاش' when 'vodafone_cash' then 'فودافون كاش' else 'إنستا باي' end,'cash_transfer_in',v_id,p_to_account);
 return v_id;
end $$;
grant execute on function public.erp_transfer_cash(date,text,text,numeric,text) to authenticated;
