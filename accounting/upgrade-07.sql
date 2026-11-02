-- AL GABAS STORE ERP - Upgrade 07: shop settings and expenses
-- Run once after upgrade-06.sql. Does not alter storefront tables.
create table if not exists public.erp_shop_settings (
 id uuid primary key default gen_random_uuid(),
 owner_id uuid not null unique references auth.users(id) on delete cascade,
 shop_name text not null default 'الجباس ستور',
 shop_name_en text not null default 'AL GABAS STORE',
 phone text,
 address text,
 currency text not null default 'EGP' check(currency='EGP'),
 invoice_prefix text not null default 'AGP',
 invoice_note text,
 updated_at timestamptz not null default now()
);
alter table public.erp_shop_settings enable row level security;
drop policy if exists erp_shop_settings_owner_all on public.erp_shop_settings;
create policy erp_shop_settings_owner_all on public.erp_shop_settings for all to authenticated using(owner_id=auth.uid()) with check(owner_id=auth.uid());
grant select,insert,update,delete on public.erp_shop_settings to authenticated;

create table if not exists public.erp_expenses (
 id uuid primary key default gen_random_uuid(),
 owner_id uuid not null references auth.users(id) on delete cascade,
 expense_date date not null default current_date,
 category text not null,
 description text not null,
 amount numeric(14,2) not null check(amount>0),
 account_code text not null check(account_code in ('drawer','vodafone_cash','instapay')),
 created_at timestamptz not null default now()
);
create index if not exists erp_expenses_owner_date_idx on public.erp_expenses(owner_id,expense_date desc);
alter table public.erp_expenses enable row level security;
drop policy if exists erp_expenses_owner_all on public.erp_expenses;
create policy erp_expenses_owner_all on public.erp_expenses for all to authenticated using(owner_id=auth.uid()) with check(owner_id=auth.uid());
grant select,insert,update,delete on public.erp_expenses to authenticated;

create or replace function public.erp_record_expense(
 p_expense_date date,p_category text,p_amount numeric,p_account_code text,p_description text
) returns uuid language plpgsql security invoker set search_path=public as $$
declare v_owner uuid:=auth.uid(); v_id uuid;
begin
 if v_owner is null then raise exception 'يجب تسجيل الدخول'; end if;
 if coalesce(trim(p_category),'')='' or coalesce(trim(p_description),'')='' then raise exception 'نوع المصروف والبيان مطلوبان'; end if;
 if p_amount is null or p_amount<=0 then raise exception 'قيمة المصروف يجب أن تكون أكبر من صفر'; end if;
 if p_account_code not in ('drawer','vodafone_cash','instapay') then raise exception 'حساب الدفع غير صحيح'; end if;
 insert into public.erp_expenses(owner_id,expense_date,category,description,amount,account_code)
 values(v_owner,coalesce(p_expense_date,current_date),trim(p_category),trim(p_description),p_amount,p_account_code) returning id into v_id;
 insert into public.erp_cash_movements(owner_id,movement_date,direction,amount,description,source_type,source_id,account_code)
 values(v_owner,coalesce(p_expense_date,current_date),'out',p_amount,'مصروف: '||trim(p_description),'expense',v_id,p_account_code);
 return v_id;
end $$;
grant execute on function public.erp_record_expense(date,text,numeric,text,text) to authenticated;
