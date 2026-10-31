-- AL GABAS PHONE ERP - Upgrade 02: simple Fawry daily closing + maintenance intake
-- Safe to run once in Supabase SQL Editor. Does not modify storefront public.products.
create table if not exists public.erp_fawry_daily_closings (
 id uuid primary key default gen_random_uuid(),
 owner_id uuid not null references auth.users(id) on delete cascade,
 close_date date not null,
 opening_balance numeric(14,2) not null default 0 check(opening_balance>=0),
 topup_amount numeric(14,2) not null default 0 check(topup_amount>=0),
 closing_balance numeric(14,2) not null default 0 check(closing_balance>=0),
 profit numeric(14,2) not null default 0 check(profit>=0),
 notes text,
 created_at timestamptz not null default now(),
 updated_at timestamptz not null default now(),
 unique(owner_id,close_date)
);
create table if not exists public.erp_cash_movements (
 id uuid primary key default gen_random_uuid(),
 owner_id uuid not null references auth.users(id) on delete cascade,
 movement_date date not null,
 direction text not null check(direction in ('in','out')),
 amount numeric(14,2) not null check(amount>0),
 description text not null,
 source_type text not null,
 source_id uuid not null,
 created_at timestamptz not null default now(),
 unique(owner_id,source_type,source_id)
);
create table if not exists public.erp_maintenance_orders (
 id uuid primary key default gen_random_uuid(),
 owner_id uuid not null references auth.users(id) on delete cascade,
 ticket_no text not null,
 customer_name text not null,
 customer_phone text,
 device_name text not null,
 device_color text,
 device_condition text,
 problem text not null,
 accessories text,
 estimated_cost numeric(14,2) not null default 0 check(estimated_cost>=0),
 labor_price numeric(14,2) not null default 0 check(labor_price>=0),
 parts_cost numeric(14,2) not null default 0 check(parts_cost>=0),
 status text not null default 'received' check(status in ('received','diagnosing','waiting_parts','in_repair','ready','delivered','cancelled')),
 received_at timestamptz not null default now(),
 delivered_at timestamptz,
 notes text,
 created_at timestamptz not null default now(),
 unique(owner_id,ticket_no)
);
alter table public.erp_fawry_daily_closings enable row level security;
alter table public.erp_cash_movements enable row level security;
alter table public.erp_maintenance_orders enable row level security;
drop policy if exists erp_fawry_closings_owner_all on public.erp_fawry_daily_closings;
create policy erp_fawry_closings_owner_all on public.erp_fawry_daily_closings for all to authenticated using(owner_id=auth.uid()) with check(owner_id=auth.uid());
drop policy if exists erp_cash_movements_owner_all on public.erp_cash_movements;
create policy erp_cash_movements_owner_all on public.erp_cash_movements for all to authenticated using(owner_id=auth.uid()) with check(owner_id=auth.uid());
drop policy if exists erp_maintenance_owner_all on public.erp_maintenance_orders;
create policy erp_maintenance_owner_all on public.erp_maintenance_orders for all to authenticated using(owner_id=auth.uid()) with check(owner_id=auth.uid());
grant select,insert,update,delete on public.erp_fawry_daily_closings,public.erp_cash_movements,public.erp_maintenance_orders to authenticated;

create or replace function public.erp_save_fawry_daily_close(
 p_close_date date,p_opening_balance numeric,p_topup_amount numeric,
 p_closing_balance numeric,p_profit numeric,p_notes text default null
) returns uuid language plpgsql security invoker set search_path=public as $$
declare v_owner uuid:=auth.uid(); v_id uuid; v_previous numeric;
begin
 if v_owner is null then raise exception 'يجب تسجيل الدخول'; end if;
 if p_opening_balance<0 or p_topup_amount<0 or p_closing_balance<0 or p_profit<0 then raise exception 'القيم لا يمكن أن تكون سالبة'; end if;
 select closing_balance into v_previous from public.erp_fawry_daily_closings
 where owner_id=v_owner and close_date<p_close_date order by close_date desc limit 1;
 if v_previous is not null and p_opening_balance<>v_previous then
   raise exception 'رصيد افتتاح اليوم يجب أن يساوي رصيد إغلاق آخر تقفيل محفوظ: %',v_previous;
 end if;
 insert into public.erp_fawry_daily_closings(owner_id,close_date,opening_balance,topup_amount,closing_balance,profit,notes)
 values(v_owner,p_close_date,p_opening_balance,p_topup_amount,p_closing_balance,p_profit,nullif(trim(p_notes),''))
 on conflict(owner_id,close_date) do update set
 opening_balance=excluded.opening_balance,topup_amount=excluded.topup_amount,
 closing_balance=excluded.closing_balance,profit=excluded.profit,notes=excluded.notes,updated_at=now()
 returning id into v_id;
 if p_topup_amount>0 then
   insert into public.erp_cash_movements(owner_id,movement_date,direction,amount,description,source_type,source_id)
   values(v_owner,p_close_date,'out',p_topup_amount,'شحن ماكينة فوري من الخزينة','fawry_topup',v_id)
   on conflict(owner_id,source_type,source_id) do update set movement_date=excluded.movement_date,direction='out',amount=excluded.amount,description=excluded.description;
 else
   delete from public.erp_cash_movements where owner_id=v_owner and source_type='fawry_topup' and source_id=v_id;
 end if;
 return v_id;
end $$;
grant execute on function public.erp_save_fawry_daily_close(date,numeric,numeric,numeric,numeric,text) to authenticated;
