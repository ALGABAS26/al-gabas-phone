-- AL GABAS STORE ERP - Upgrade 11: link sold IMEI units to exact sale lines
-- Run after upgrades 08, 09 and 10. Does not modify storefront tables.
create table if not exists public.erp_sales_invoice_item_units (
 id uuid primary key default gen_random_uuid(),
 owner_id uuid not null references auth.users(id) on delete cascade,
 invoice_item_id uuid not null references public.erp_sales_invoice_items(id) on delete cascade,
 product_unit_id uuid not null references public.erp_product_units(id),
 created_at timestamptz not null default now(),
 unique(owner_id, invoice_item_id, product_unit_id),
 unique(owner_id, product_unit_id)
);
create index if not exists erp_sale_item_units_line_idx
 on public.erp_sales_invoice_item_units(owner_id,invoice_item_id);
alter table public.erp_sales_invoice_item_units enable row level security;
drop policy if exists erp_sale_item_units_owner_all on public.erp_sales_invoice_item_units;
create policy erp_sale_item_units_owner_all on public.erp_sales_invoice_item_units
 for all to authenticated using(owner_id=auth.uid()) with check(owner_id=auth.uid());
grant select,insert,update,delete on public.erp_sales_invoice_item_units to authenticated;

-- The sales RPC marks the selected devices sold before inserting the invoice line.
-- This trigger binds exactly those newly sold, not-yet-linked units to that line.
create or replace function public.erp_link_sold_units_to_sale_line()
returns trigger language plpgsql security invoker set search_path=public as $$
declare v_units integer; v_linked integer;
begin
 select count(*) into v_units from public.erp_product_units
 where owner_id=new.owner_id and product_id=new.product_id;
 if v_units=0 then return new; end if;

 with picked as (
  select u.id from public.erp_product_units u
  where u.owner_id=new.owner_id and u.product_id=new.product_id
    and u.status='sold'
    and not exists(select 1 from public.erp_sales_invoice_item_units x
                   where x.owner_id=u.owner_id and x.product_unit_id=u.id)
  order by u.created_at,u.id
  limit new.quantity
  for update
 )
 insert into public.erp_sales_invoice_item_units(owner_id,invoice_item_id,product_unit_id)
 select new.owner_id,new.id,p.id from picked p
 on conflict do nothing;
 get diagnostics v_linked = row_count;
 if v_linked<>new.quantity then
  raise exception 'تعذر ربط أرقام IMEI بسطر فاتورة البيع؛ تم إلغاء العملية لحماية سجل الأجهزة';
 end if;
 return new;
end $$;
drop trigger if exists erp_link_sold_units_after_sale_line on public.erp_sales_invoice_items;
create trigger erp_link_sold_units_after_sale_line
after insert on public.erp_sales_invoice_items
for each row execute function public.erp_link_sold_units_to_sale_line();

-- Replace the earlier blanket block: only allow a tracked-product return when
-- enough exact sold IMEI units belong to the original invoice line.
create or replace function public.erp_guard_imei_return()
returns trigger language plpgsql security invoker set search_path=public as $$
declare v_tracked integer; v_available integer;
begin
 select count(*) into v_tracked from public.erp_product_units
 where owner_id=new.owner_id and product_id=new.product_id;
 if v_tracked=0 then return new; end if;
 select count(*) into v_available
 from public.erp_sales_invoice_item_units x
 join public.erp_product_units u on u.id=x.product_unit_id and u.owner_id=x.owner_id
 where x.owner_id=new.owner_id and x.invoice_item_id=new.invoice_item_id
   and u.product_id=new.product_id and u.status='sold';
 if v_available<new.quantity then
  raise exception 'مرتجع IMEI غير متاح: لا توجد أرقام أجهزة مباعة كافية مرتبطة بسطر الفاتورة الأصلي';
 end if;
 return new;
end $$;

-- Mark the exact returned serials as returned, never an arbitrary device.
create or replace function public.erp_mark_returned_imei_units()
returns trigger language plpgsql security invoker set search_path=public as $$
declare v_changed integer;
begin
 if not exists(select 1 from public.erp_product_units
               where owner_id=new.owner_id and product_id=new.product_id) then
  return new;
 end if;
 with picked as (
  select u.id from public.erp_sales_invoice_item_units x
  join public.erp_product_units u on u.id=x.product_unit_id and u.owner_id=x.owner_id
  where x.owner_id=new.owner_id and x.invoice_item_id=new.invoice_item_id
    and u.product_id=new.product_id and u.status='sold'
  order by u.created_at,u.id
  limit new.quantity
  for update of u
 )
 update public.erp_product_units u set status='returned'
 from picked p where u.id=p.id and u.owner_id=new.owner_id and u.status='sold';
 get diagnostics v_changed = row_count;
 if v_changed<>new.quantity then
  raise exception 'تعذر تحديث حالة أرقام IMEI للمرتجع؛ تم إلغاء العملية';
 end if;
 return new;
end $$;
drop trigger if exists erp_mark_returned_imei_after_item on public.erp_return_items;
create trigger erp_mark_returned_imei_after_item
after insert on public.erp_return_items
for each row execute function public.erp_mark_returned_imei_units();

-- Legacy invoices created before this upgrade have no exact serial association.
-- Their IMEI returns remain blocked intentionally; new sales are linked automatically.
