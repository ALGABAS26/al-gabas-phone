-- AL GABAS PHONE ERP - Upgrade 06: purchase invoices and stock receiving
-- Run once after upgrade-05.sql. Storefront public.products is not modified.
create table if not exists public.erp_purchase_invoices (
 id uuid primary key default gen_random_uuid(),
 owner_id uuid not null references auth.users(id) on delete cascade,
 invoice_no text not null, invoice_date date not null default current_date,
 supplier_id uuid references public.erp_parties(id) on delete set null,
 supplier_name text not null default 'مورد نقدي',
 subtotal numeric(14,2) not null check(subtotal>=0),
 discount numeric(14,2) not null default 0 check(discount>=0),
 total numeric(14,2) not null check(total>=0),
 paid numeric(14,2) not null default 0 check(paid>=0 and paid<=total),
 remaining numeric(14,2) generated always as (total-paid) stored,
 notes text, created_at timestamptz not null default now(),
 unique(owner_id,invoice_no)
);
create table if not exists public.erp_purchase_invoice_items (
 id uuid primary key default gen_random_uuid(),
 owner_id uuid not null references auth.users(id) on delete cascade,
 invoice_id uuid not null references public.erp_purchase_invoices(id) on delete cascade,
 product_id uuid not null references public.erp_products(id),
 product_name text not null, quantity integer not null check(quantity>0),
 unit_cost numeric(14,2) not null check(unit_cost>=0),
 line_total numeric(14,2) not null check(line_total>=0)
);
create table if not exists public.erp_purchase_payments (
 id uuid primary key default gen_random_uuid(),
 owner_id uuid not null references auth.users(id) on delete cascade,
 invoice_id uuid not null references public.erp_purchase_invoices(id) on delete cascade,
 account_code text not null check(account_code in ('drawer','vodafone_cash','instapay')),
 amount numeric(14,2) not null check(amount>0), created_at timestamptz not null default now()
);
create index if not exists erp_purchase_date_idx on public.erp_purchase_invoices(owner_id,invoice_date desc);
create index if not exists erp_purchase_items_invoice_idx on public.erp_purchase_invoice_items(invoice_id);
create index if not exists erp_purchase_payments_invoice_idx on public.erp_purchase_payments(invoice_id);
alter table public.erp_purchase_invoices enable row level security;
alter table public.erp_purchase_invoice_items enable row level security;
alter table public.erp_purchase_payments enable row level security;
drop policy if exists erp_purchase_invoices_owner_all on public.erp_purchase_invoices;
create policy erp_purchase_invoices_owner_all on public.erp_purchase_invoices for all to authenticated using(owner_id=auth.uid()) with check(owner_id=auth.uid());
drop policy if exists erp_purchase_items_owner_all on public.erp_purchase_invoice_items;
create policy erp_purchase_items_owner_all on public.erp_purchase_invoice_items for all to authenticated using(owner_id=auth.uid()) with check(owner_id=auth.uid());
drop policy if exists erp_purchase_payments_owner_all on public.erp_purchase_payments;
create policy erp_purchase_payments_owner_all on public.erp_purchase_payments for all to authenticated using(owner_id=auth.uid()) with check(owner_id=auth.uid());
grant select,insert,update,delete on public.erp_purchase_invoices,public.erp_purchase_invoice_items,public.erp_purchase_payments to authenticated;

create or replace function public.erp_create_purchase(
 p_invoice_no text,p_invoice_date date,p_supplier_id uuid,p_discount numeric,
 p_notes text,p_items jsonb,p_payments jsonb
) returns uuid language plpgsql security invoker set search_path=public as $$
declare
 v_owner uuid:=auth.uid(); v_invoice uuid; v_subtotal numeric(14,2):=0;
 v_total numeric(14,2); v_paid numeric(14,2):=0; v_item jsonb; v_payment jsonb;
 v_product public.erp_products%rowtype; v_qty integer; v_cost numeric(14,2);
 v_account text; v_amount numeric(14,2); v_payment_id uuid;
 v_supplier_name text:='مورد نقدي'; v_new_cost numeric(14,2);
begin
 if v_owner is null then raise exception 'يجب تسجيل الدخول'; end if;
 if coalesce(trim(p_invoice_no),'')='' then raise exception 'رقم الفاتورة مطلوب'; end if;
 if jsonb_typeof(p_items)<>'array' or jsonb_array_length(p_items)=0 then raise exception 'أضف صنفًا واحدًا على الأقل'; end if;
 if jsonb_typeof(p_payments)<>'array' then raise exception 'بيانات الدفع غير صحيحة'; end if;
 if coalesce(p_discount,0)<0 then raise exception 'الخصم غير صحيح'; end if;
 if exists(select 1 from jsonb_array_elements(p_items) with ordinality a(value,ord), jsonb_array_elements(p_items) with ordinality b(value,ord) where a.ord<b.ord and a.value->>'product_id'=b.value->>'product_id') then raise exception 'لا تكرر نفس المنتج في سطرين؛ اجمع الكمية في سطر واحد'; end if;
 if p_supplier_id is not null then
  select name into v_supplier_name from public.erp_parties where id=p_supplier_id and owner_id=v_owner and party_type='supplier' for update;
  if not found then raise exception 'المورد المحدد غير موجود'; end if;
 end if;
 for v_item in select value from jsonb_array_elements(p_items) loop
  v_qty:=(v_item->>'quantity')::integer; v_cost:=(v_item->>'unit_cost')::numeric;
  if v_qty<=0 or v_cost<0 then raise exception 'الكمية أو تكلفة الشراء غير صحيحة'; end if;
  select * into v_product from public.erp_products where id=(v_item->>'product_id')::uuid and owner_id=v_owner for update;
  if not found then raise exception 'أحد المنتجات غير موجود'; end if;
  v_subtotal:=v_subtotal+(v_qty*v_cost);
 end loop;
 if coalesce(p_discount,0)>v_subtotal then raise exception 'الخصم أكبر من إجمالي الفاتورة'; end if;
 v_total:=v_subtotal-coalesce(p_discount,0);
 for v_payment in select value from jsonb_array_elements(p_payments) loop
  v_account:=v_payment->>'account_code'; v_amount:=(v_payment->>'amount')::numeric;
  if v_account not in ('drawer','vodafone_cash','instapay') or v_amount<0 then raise exception 'طريقة الدفع غير صحيحة'; end if;
  if v_amount>0 then v_paid:=v_paid+v_amount; end if;
 end loop;
 if v_paid>v_total then raise exception 'إجمالي المدفوع أكبر من قيمة الفاتورة'; end if;
 if v_paid<v_total and p_supplier_id is null then raise exception 'اختر المورد لتسجيل المبلغ المتبقي كمديونية عليه'; end if;
 insert into public.erp_purchase_invoices(owner_id,invoice_no,invoice_date,supplier_id,supplier_name,subtotal,discount,total,paid,notes)
 values(v_owner,trim(p_invoice_no),coalesce(p_invoice_date,current_date),p_supplier_id,v_supplier_name,v_subtotal,coalesce(p_discount,0),v_total,v_paid,nullif(trim(p_notes),'')) returning id into v_invoice;
 for v_item in select value from jsonb_array_elements(p_items) loop
  v_qty:=(v_item->>'quantity')::integer; v_cost:=(v_item->>'unit_cost')::numeric;
  select * into v_product from public.erp_products where id=(v_item->>'product_id')::uuid and owner_id=v_owner for update;
  if v_product.quantity+v_qty>0 then
   v_new_cost:=((v_product.quantity*coalesce(v_product.cost_price,0))+(v_qty*v_cost))/(v_product.quantity+v_qty);
  else v_new_cost:=v_cost; end if;
  update public.erp_products set quantity=quantity+v_qty,cost_price=round(v_new_cost,2),updated_at=now() where id=v_product.id and owner_id=v_owner;
  insert into public.erp_purchase_invoice_items(owner_id,invoice_id,product_id,product_name,quantity,unit_cost,line_total)
  values(v_owner,v_invoice,v_product.id,v_product.name,v_qty,v_cost,v_qty*v_cost);
 end loop;
 if p_supplier_id is not null then
  if v_total>0 then insert into public.erp_party_transactions(owner_id,party_id,transaction_date,direction,amount,description)
   values(v_owner,p_supplier_id,coalesce(p_invoice_date,current_date),'increase',v_total,'فاتورة شراء رقم '||trim(p_invoice_no)); end if;
  if v_paid>0 then insert into public.erp_party_transactions(owner_id,party_id,transaction_date,direction,amount,description)
   values(v_owner,p_supplier_id,coalesce(p_invoice_date,current_date),'decrease',v_paid,'سداد من فاتورة شراء رقم '||trim(p_invoice_no)); end if;
 end if;
 for v_payment in select value from jsonb_array_elements(p_payments) loop
  v_account:=v_payment->>'account_code'; v_amount:=(v_payment->>'amount')::numeric;
  if v_amount>0 then
   insert into public.erp_purchase_payments(owner_id,invoice_id,account_code,amount) values(v_owner,v_invoice,v_account,v_amount) returning id into v_payment_id;
   insert into public.erp_cash_movements(owner_id,movement_date,direction,amount,description,source_type,source_id,account_code)
   values(v_owner,coalesce(p_invoice_date,current_date),'out',v_amount,'سداد فاتورة مشتريات رقم '||trim(p_invoice_no),'purchase_payment',v_payment_id,v_account);
  end if;
 end loop;
 return v_invoice;
end $$;
grant execute on function public.erp_create_purchase(text,date,uuid,numeric,text,jsonb,jsonb) to authenticated;
