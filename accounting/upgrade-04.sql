-- AL GABAS PHONE ERP - Upgrade 04: atomic sales invoices with split payments
-- Run after upgrade-03.sql. Isolated from storefront public.products.
create table if not exists public.erp_sales_invoices (
 id uuid primary key default gen_random_uuid(),
 owner_id uuid not null references auth.users(id) on delete cascade,
 invoice_no text not null,
 invoice_date date not null default current_date,
 customer_name text not null default 'عميل نقدي',
 customer_phone text,
 subtotal numeric(14,2) not null check(subtotal>=0),
 discount numeric(14,2) not null default 0 check(discount>=0),
 total numeric(14,2) not null check(total>=0),
 paid numeric(14,2) not null default 0 check(paid>=0 and paid<=total),
 remaining numeric(14,2) generated always as (total-paid) stored,
 notes text,
 status text not null default 'completed' check(status in ('completed','cancelled')),
 created_at timestamptz not null default now(),
 unique(owner_id,invoice_no)
);
create table if not exists public.erp_sales_invoice_items (
 id uuid primary key default gen_random_uuid(),
 owner_id uuid not null references auth.users(id) on delete cascade,
 invoice_id uuid not null references public.erp_sales_invoices(id) on delete cascade,
 product_id uuid not null references public.erp_products(id),
 product_name text not null,
 quantity integer not null check(quantity>0),
 unit_price numeric(14,2) not null check(unit_price>=0),
 unit_cost numeric(14,2) not null check(unit_cost>=0),
 line_total numeric(14,2) not null check(line_total>=0)
);
create table if not exists public.erp_sales_payments (
 id uuid primary key default gen_random_uuid(),
 owner_id uuid not null references auth.users(id) on delete cascade,
 invoice_id uuid not null references public.erp_sales_invoices(id) on delete cascade,
 account_code text not null check(account_code in ('drawer','vodafone_cash','instapay')),
 amount numeric(14,2) not null check(amount>0),
 created_at timestamptz not null default now()
);
create index if not exists erp_sales_date_idx on public.erp_sales_invoices(owner_id,invoice_date desc);
create index if not exists erp_sales_items_invoice_idx on public.erp_sales_invoice_items(invoice_id);
create index if not exists erp_sales_payments_invoice_idx on public.erp_sales_payments(invoice_id);
alter table public.erp_sales_invoices enable row level security;
alter table public.erp_sales_invoice_items enable row level security;
alter table public.erp_sales_payments enable row level security;
drop policy if exists erp_sales_invoices_owner_all on public.erp_sales_invoices;
create policy erp_sales_invoices_owner_all on public.erp_sales_invoices for all to authenticated using(owner_id=auth.uid()) with check(owner_id=auth.uid());
drop policy if exists erp_sales_items_owner_all on public.erp_sales_invoice_items;
create policy erp_sales_items_owner_all on public.erp_sales_invoice_items for all to authenticated using(owner_id=auth.uid()) with check(owner_id=auth.uid());
drop policy if exists erp_sales_payments_owner_all on public.erp_sales_payments;
create policy erp_sales_payments_owner_all on public.erp_sales_payments for all to authenticated using(owner_id=auth.uid()) with check(owner_id=auth.uid());
grant select,insert,update,delete on public.erp_sales_invoices,public.erp_sales_invoice_items,public.erp_sales_payments to authenticated;

create or replace function public.erp_create_sale(
 p_invoice_no text,
 p_invoice_date date,
 p_customer_name text,
 p_customer_phone text,
 p_discount numeric,
 p_notes text,
 p_items jsonb,
 p_payments jsonb
) returns uuid
language plpgsql security invoker set search_path=public as $$
declare
 v_owner uuid:=auth.uid(); v_invoice uuid; v_subtotal numeric(14,2):=0;
 v_total numeric(14,2); v_paid numeric(14,2):=0; v_item jsonb; v_payment jsonb;
 v_product public.erp_products%rowtype; v_qty integer; v_price numeric(14,2);
 v_units integer; v_account text; v_amount numeric(14,2); v_payment_id uuid;
begin
 if v_owner is null then raise exception 'يجب تسجيل الدخول'; end if;
 if coalesce(trim(p_invoice_no),'')='' then raise exception 'رقم الفاتورة مطلوب'; end if;
 if jsonb_typeof(p_items)<>'array' or jsonb_array_length(p_items)=0 then raise exception 'أضف منتجًا واحدًا على الأقل'; end if;
 if jsonb_typeof(p_payments)<>'array' then raise exception 'بيانات التحصيل غير صحيحة'; end if;
 if coalesce(p_discount,0)<0 then raise exception 'الخصم غير صحيح'; end if;

 -- Validate and lock products, then calculate invoice subtotal.
 for v_item in select value from jsonb_array_elements(p_items) loop
   v_qty:=(v_item->>'quantity')::integer;
   v_price:=(v_item->>'unit_price')::numeric;
   if v_qty<=0 or v_price<0 then raise exception 'الكمية أو السعر غير صحيح'; end if;
   select * into v_product from public.erp_products
     where id=(v_item->>'product_id')::uuid and owner_id=v_owner for update;
   if not found then raise exception 'أحد المنتجات غير موجود'; end if;
   if v_product.quantity<v_qty then raise exception 'الكمية غير كافية للمنتج: % (المتاح %)',v_product.name,v_product.quantity; end if;
   select count(*) into v_units from public.erp_product_units
     where owner_id=v_owner and product_id=v_product.id;
   if v_units>0 then
     if (select count(*) from public.erp_product_units where owner_id=v_owner and product_id=v_product.id and status='in_stock')<v_qty then
       raise exception 'أجهزة IMEI المتاحة غير كافية للمنتج: %',v_product.name;
     end if;
   end if;
   v_subtotal:=v_subtotal+(v_qty*v_price);
 end loop;
 if p_discount>v_subtotal then raise exception 'الخصم أكبر من إجمالي الفاتورة'; end if;
 v_total:=v_subtotal-coalesce(p_discount,0);

 for v_payment in select value from jsonb_array_elements(p_payments) loop
   v_account:=v_payment->>'account_code'; v_amount:=(v_payment->>'amount')::numeric;
   if v_account not in ('drawer','vodafone_cash','instapay') or v_amount<0 then raise exception 'طريقة التحصيل غير صحيحة'; end if;
   if v_amount>0 then v_paid:=v_paid+v_amount; end if;
 end loop;
 if v_paid>v_total then raise exception 'إجمالي التحصيل أكبر من قيمة الفاتورة'; end if;

 insert into public.erp_sales_invoices(owner_id,invoice_no,invoice_date,customer_name,customer_phone,subtotal,discount,total,paid,notes)
 values(v_owner,trim(p_invoice_no),coalesce(p_invoice_date,current_date),coalesce(nullif(trim(p_customer_name),''),'عميل نقدي'),nullif(trim(p_customer_phone),''),v_subtotal,coalesce(p_discount,0),v_total,v_paid,nullif(trim(p_notes),''))
 returning id into v_invoice;

 for v_item in select value from jsonb_array_elements(p_items) loop
   v_qty:=(v_item->>'quantity')::integer; v_price:=(v_item->>'unit_price')::numeric;
   select * into v_product from public.erp_products where id=(v_item->>'product_id')::uuid and owner_id=v_owner for update;
   update public.erp_products set quantity=quantity-v_qty,updated_at=now() where id=v_product.id and owner_id=v_owner;
   select count(*) into v_units from public.erp_product_units where owner_id=v_owner and product_id=v_product.id;
   if v_units>0 then
     with picked as (
       select id from public.erp_product_units where owner_id=v_owner and product_id=v_product.id and status='in_stock'
       order by created_at,id limit v_qty for update
     )
     update public.erp_product_units u set status='sold' from picked where u.id=picked.id;
   end if;
   insert into public.erp_sales_invoice_items(owner_id,invoice_id,product_id,product_name,quantity,unit_price,unit_cost,line_total)
   values(v_owner,v_invoice,v_product.id,v_product.name,v_qty,v_price,v_product.cost_price,v_qty*v_price);
 end loop;

 for v_payment in select value from jsonb_array_elements(p_payments) loop
   v_account:=v_payment->>'account_code'; v_amount:=(v_payment->>'amount')::numeric;
   if v_amount>0 then
     insert into public.erp_sales_payments(owner_id,invoice_id,account_code,amount) values(v_owner,v_invoice,v_account,v_amount) returning id into v_payment_id;
     insert into public.erp_cash_movements(owner_id,movement_date,direction,amount,description,source_type,source_id,account_code)
     values(v_owner,coalesce(p_invoice_date,current_date),'in',v_amount,'تحصيل فاتورة مبيعات رقم '||trim(p_invoice_no),'sale_payment',v_payment_id,v_account);
   end if;
 end loop;
 return v_invoice;
end $$;
grant execute on function public.erp_create_sale(text,date,text,text,numeric,text,jsonb,jsonb) to authenticated;
