-- AL GABAS STORE ERP - Upgrade 12: transactional IMEI receiving and purchase returns
-- Run after upgrades 08, 09, 10 and 11. Does not touch storefront public.products.
create table if not exists public.erp_purchase_invoice_item_units (
 id uuid primary key default gen_random_uuid(),
 owner_id uuid not null references auth.users(id) on delete cascade,
 invoice_item_id uuid not null references public.erp_purchase_invoice_items(id) on delete cascade,
 product_unit_id uuid not null references public.erp_product_units(id),
 created_at timestamptz not null default now(),
 unique(owner_id,invoice_item_id,product_unit_id),
 unique(owner_id,product_unit_id)
);
create index if not exists erp_purchase_item_units_line_idx on public.erp_purchase_invoice_item_units(owner_id,invoice_item_id);
-- Enforce ownership and product/line consistency even if a client writes to the
-- mapping table directly instead of using the purchase RPC.
create or replace function public.erp_guard_purchase_unit_link()
returns trigger language plpgsql security invoker set search_path=public as $
declare v_line_owner uuid; v_line_product uuid; v_unit_owner uuid; v_unit_product uuid;
begin
 select owner_id,product_id into v_line_owner,v_line_product
 from public.erp_purchase_invoice_items where id=new.invoice_item_id;
 select owner_id,product_id into v_unit_owner,v_unit_product
 from public.erp_product_units where id=new.product_unit_id;
 if v_line_owner is null or v_unit_owner is null
    or v_line_owner<>new.owner_id or v_unit_owner<>new.owner_id
    or v_line_product<>v_unit_product then
  raise exception 'ربط رقم IMEI يجب أن يكون مع صنف وفاتورة من نفس الحساب';
 end if;
 return new;
end $;
drop trigger if exists erp_purchase_unit_link_guard on public.erp_purchase_invoice_item_units;
create trigger erp_purchase_unit_link_guard
before insert or update on public.erp_purchase_invoice_item_units
for each row execute function public.erp_guard_purchase_unit_link();

-- Validate the IMEI check digit in the database too, not only in the browser.
create or replace function public.erp_imei_luhn_valid(p_imei text)
returns boolean language plpgsql immutable strict as $
declare v_sum integer:=0; v_digit integer; v_double boolean:=false; i integer;
begin
 if p_imei !~ '^[0-9]{15}
alter table public.erp_purchase_invoice_item_units enable row level security;
drop policy if exists erp_purchase_item_units_owner_all on public.erp_purchase_invoice_item_units;
create policy erp_purchase_item_units_owner_all on public.erp_purchase_invoice_item_units
 for all to authenticated using(owner_id=auth.uid()) with check(owner_id=auth.uid());
grant select,insert,update,delete on public.erp_purchase_invoice_item_units to authenticated;

create or replace function public.erp_create_purchase(
 p_invoice_no text,p_invoice_date date,p_supplier_id uuid,p_discount numeric,
 p_notes text,p_items jsonb,p_payments jsonb
) returns uuid language plpgsql security invoker set search_path=public as $$
declare
 v_owner uuid:=auth.uid(); v_invoice uuid; v_subtotal numeric(14,2):=0;
 v_total numeric(14,2); v_paid numeric(14,2):=0; v_item jsonb; v_payment jsonb;
 v_product public.erp_products%rowtype; v_qty integer; v_cost numeric(14,2);
 v_account text; v_amount numeric(14,2); v_payment_id uuid;
 v_supplier_name text:='مورد نقدي'; v_new_cost numeric(14,2); v_invoice_item uuid; v_units jsonb; v_unit jsonb; v_imei1 text; v_imei2 text; v_unit_barcode text; v_tracked integer;
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
  v_units:=coalesce(v_item->'imei_units','[]'::jsonb);
  if jsonb_typeof(v_units)<>'array' then raise exception 'بيانات IMEI غير صحيحة'; end if;
  if jsonb_array_length(v_units)>0 and jsonb_array_length(v_units)<>v_qty then raise exception 'عدد أرقام IMEI يجب أن يساوي كمية الصنف'; end if;
  select * into v_product from public.erp_products where id=(v_item->>'product_id')::uuid and owner_id=v_owner for update;
  if not found then raise exception 'أحد المنتجات غير موجود'; end if;
  select count(*) into v_tracked from public.erp_product_units where owner_id=v_owner and product_id=v_product.id;
  if v_tracked>0 and jsonb_array_length(v_units)<>v_qty then raise exception 'هذا المنتج مسجل بتتبع IMEI؛ أدخل أرقام كل الأجهزة في فاتورة الشراء'; end if;
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
  values(v_owner,v_invoice,v_product.id,v_product.name,v_qty,v_cost,v_qty*v_cost) returning id into v_invoice_item;
  v_units:=coalesce(v_item->'imei_units','[]'::jsonb);
  for v_unit in select value from jsonb_array_elements(v_units) loop
   v_imei1:=nullif(regexp_replace(coalesce(v_unit->>'imei1',''),'[^0-9]','','g'),'');
   v_imei2:=nullif(regexp_replace(coalesce(v_unit->>'imei2',''),'[^0-9]','','g'),'');
   if v_imei1 is null and v_imei2 is null then raise exception 'كل جهاز متتبع يجب أن يحتوي على IMEI واحد على الأقل'; end if;
   if (v_imei1 is not null and not public.erp_imei_luhn_valid(v_imei1)) or (v_imei2 is not null and not public.erp_imei_luhn_valid(v_imei2)) or v_imei1=v_imei2 then raise exception 'رقم IMEI غير صحيح أو لا يجتاز فحص الرقم'; end if;
   v_unit_barcode:='IMEI-'||coalesce(v_imei1,v_imei2);
   insert into public.erp_product_units(owner_id,product_id,imei1,imei2,unit_barcode,purchase_price,status)
   values(v_owner,v_product.id,v_imei1,v_imei2,v_unit_barcode,v_cost,'in_stock')
   returning id into v_payment_id;
   insert into public.erp_purchase_invoice_item_units(owner_id,invoice_item_id,product_unit_id)
   values(v_owner,v_invoice_item,v_payment_id);
  end loop;
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

-- Validate both sale and purchase returns against the exact source invoice line.
create or replace function public.erp_guard_imei_return()
returns trigger language plpgsql security invoker set search_path=public as $$
declare v_type text; v_available integer; v_tracked integer;
begin
 select return_type into v_type from public.erp_returns where id=new.return_id and owner_id=new.owner_id;
 if v_type is null then raise exception 'نوع المرتجع غير معروف'; end if;
 select count(*) into v_tracked from public.erp_product_units where owner_id=new.owner_id and product_id=new.product_id;
 if v_tracked=0 then return new; end if;
 if v_type='sale' then
  select count(*) into v_available from public.erp_sales_invoice_item_units x
  join public.erp_product_units u on u.id=x.product_unit_id and u.owner_id=x.owner_id
  where x.owner_id=new.owner_id and x.invoice_item_id=new.invoice_item_id and u.product_id=new.product_id and u.status='sold';
 else
  select count(*) into v_available from public.erp_purchase_invoice_item_units x
  join public.erp_product_units u on u.id=x.product_unit_id and u.owner_id=x.owner_id
  where x.owner_id=new.owner_id and x.invoice_item_id=new.invoice_item_id and u.product_id=new.product_id and u.status='in_stock';
 end if;
 if v_available<new.quantity then raise exception 'لا توجد أرقام IMEI متاحة كافية مرتبطة بسطر الفاتورة الأصلي'; end if;
 return new;
end $$;

create or replace function public.erp_mark_returned_imei_units()
returns trigger language plpgsql security invoker set search_path=public as $$
declare v_type text; v_changed integer;
begin
 select return_type into v_type from public.erp_returns where id=new.return_id and owner_id=new.owner_id;
 if not exists(select 1 from public.erp_product_units where owner_id=new.owner_id and product_id=new.product_id) then return new; end if;
 if v_type='sale' then
  with picked as (
   select u.id from public.erp_sales_invoice_item_units x
   join public.erp_product_units u on u.id=x.product_unit_id and u.owner_id=x.owner_id
   where x.owner_id=new.owner_id and x.invoice_item_id=new.invoice_item_id and u.product_id=new.product_id and u.status='sold'
   order by u.created_at,u.id limit new.quantity for update of u
  )
  update public.erp_product_units u set status='returned' from picked p where u.id=p.id and u.owner_id=new.owner_id and u.status='sold';
 else
  with picked as (
   select u.id from public.erp_purchase_invoice_item_units x
   join public.erp_product_units u on u.id=x.product_unit_id and u.owner_id=x.owner_id
   where x.owner_id=new.owner_id and x.invoice_item_id=new.invoice_item_id and u.product_id=new.product_id and u.status='in_stock'
   order by u.created_at,u.id limit new.quantity for update of u
  )
  update public.erp_product_units u set status='returned' from picked p where u.id=p.id and u.owner_id=new.owner_id and u.status='in_stock';
 end if;
 get diagnostics v_changed = row_count;
 if v_changed<>new.quantity then raise exception 'تعذر تحديث أرقام IMEI للمرتجع؛ تم إلغاء العملية'; end if;
 return new;
end $$;
 then return false; end if;
 for i in reverse length(p_imei)..1 loop
  v_digit:=substring(p_imei from i for 1)::integer;
  if v_double then v_digit:=v_digit*2; if v_digit>9 then v_digit:=v_digit-9; end if; end if;
  v_sum:=v_sum+v_digit; v_double:=not v_double;
 end loop;
 return v_sum%10=0;
end $;

alter table public.erp_purchase_invoice_item_units enable row level security;
drop policy if exists erp_purchase_item_units_owner_all on public.erp_purchase_invoice_item_units;
create policy erp_purchase_item_units_owner_all on public.erp_purchase_invoice_item_units
 for all to authenticated using(owner_id=auth.uid()) with check(owner_id=auth.uid());
grant select,insert,update,delete on public.erp_purchase_invoice_item_units to authenticated;

create or replace function public.erp_create_purchase(
 p_invoice_no text,p_invoice_date date,p_supplier_id uuid,p_discount numeric,
 p_notes text,p_items jsonb,p_payments jsonb
) returns uuid language plpgsql security invoker set search_path=public as $$
declare
 v_owner uuid:=auth.uid(); v_invoice uuid; v_subtotal numeric(14,2):=0;
 v_total numeric(14,2); v_paid numeric(14,2):=0; v_item jsonb; v_payment jsonb;
 v_product public.erp_products%rowtype; v_qty integer; v_cost numeric(14,2);
 v_account text; v_amount numeric(14,2); v_payment_id uuid;
 v_supplier_name text:='مورد نقدي'; v_new_cost numeric(14,2); v_invoice_item uuid; v_units jsonb; v_unit jsonb; v_imei1 text; v_imei2 text; v_unit_barcode text; v_tracked integer;
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
  v_units:=coalesce(v_item->'imei_units','[]'::jsonb);
  if jsonb_typeof(v_units)<>'array' then raise exception 'بيانات IMEI غير صحيحة'; end if;
  if jsonb_array_length(v_units)>0 and jsonb_array_length(v_units)<>v_qty then raise exception 'عدد أرقام IMEI يجب أن يساوي كمية الصنف'; end if;
  select * into v_product from public.erp_products where id=(v_item->>'product_id')::uuid and owner_id=v_owner for update;
  if not found then raise exception 'أحد المنتجات غير موجود'; end if;
  select count(*) into v_tracked from public.erp_product_units where owner_id=v_owner and product_id=v_product.id;
  if v_tracked>0 and jsonb_array_length(v_units)<>v_qty then raise exception 'هذا المنتج مسجل بتتبع IMEI؛ أدخل أرقام كل الأجهزة في فاتورة الشراء'; end if;
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
  values(v_owner,v_invoice,v_product.id,v_product.name,v_qty,v_cost,v_qty*v_cost) returning id into v_invoice_item;
  v_units:=coalesce(v_item->'imei_units','[]'::jsonb);
  for v_unit in select value from jsonb_array_elements(v_units) loop
   v_imei1:=nullif(regexp_replace(coalesce(v_unit->>'imei1',''),'[^0-9]','','g'),'');
   v_imei2:=nullif(regexp_replace(coalesce(v_unit->>'imei2',''),'[^0-9]','','g'),'');
   if v_imei1 is null and v_imei2 is null then raise exception 'كل جهاز متتبع يجب أن يحتوي على IMEI واحد على الأقل'; end if;
   if (v_imei1 is not null and length(v_imei1)<>15) or (v_imei2 is not null and length(v_imei2)<>15) or v_imei1=v_imei2 then raise exception 'رقم IMEI غير صحيح'; end if;
   v_unit_barcode:='IMEI-'||coalesce(v_imei1,v_imei2);
   insert into public.erp_product_units(owner_id,product_id,imei1,imei2,unit_barcode,purchase_price,status)
   values(v_owner,v_product.id,v_imei1,v_imei2,v_unit_barcode,v_cost,'in_stock')
   returning id into v_payment_id;
   insert into public.erp_purchase_invoice_item_units(owner_id,invoice_item_id,product_unit_id)
   values(v_owner,v_invoice_item,v_payment_id);
  end loop;
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

-- Validate both sale and purchase returns against the exact source invoice line.
create or replace function public.erp_guard_imei_return()
returns trigger language plpgsql security invoker set search_path=public as $$
declare v_type text; v_available integer; v_tracked integer;
begin
 select return_type into v_type from public.erp_returns where id=new.return_id and owner_id=new.owner_id;
 if v_type is null then raise exception 'نوع المرتجع غير معروف'; end if;
 select count(*) into v_tracked from public.erp_product_units where owner_id=new.owner_id and product_id=new.product_id;
 if v_tracked=0 then return new; end if;
 if v_type='sale' then
  select count(*) into v_available from public.erp_sales_invoice_item_units x
  join public.erp_product_units u on u.id=x.product_unit_id and u.owner_id=x.owner_id
  where x.owner_id=new.owner_id and x.invoice_item_id=new.invoice_item_id and u.product_id=new.product_id and u.status='sold';
 else
  select count(*) into v_available from public.erp_purchase_invoice_item_units x
  join public.erp_product_units u on u.id=x.product_unit_id and u.owner_id=x.owner_id
  where x.owner_id=new.owner_id and x.invoice_item_id=new.invoice_item_id and u.product_id=new.product_id and u.status='in_stock';
 end if;
 if v_available<new.quantity then raise exception 'لا توجد أرقام IMEI متاحة كافية مرتبطة بسطر الفاتورة الأصلي'; end if;
 return new;
end $$;

create or replace function public.erp_mark_returned_imei_units()
returns trigger language plpgsql security invoker set search_path=public as $$
declare v_type text; v_changed integer;
begin
 select return_type into v_type from public.erp_returns where id=new.return_id and owner_id=new.owner_id;
 if not exists(select 1 from public.erp_product_units where owner_id=new.owner_id and product_id=new.product_id) then return new; end if;
 if v_type='sale' then
  with picked as (
   select u.id from public.erp_sales_invoice_item_units x
   join public.erp_product_units u on u.id=x.product_unit_id and u.owner_id=x.owner_id
   where x.owner_id=new.owner_id and x.invoice_item_id=new.invoice_item_id and u.product_id=new.product_id and u.status='sold'
   order by u.created_at,u.id limit new.quantity for update of u
  )
  update public.erp_product_units u set status='returned' from picked p where u.id=p.id and u.owner_id=new.owner_id and u.status='sold';
 else
  with picked as (
   select u.id from public.erp_purchase_invoice_item_units x
   join public.erp_product_units u on u.id=x.product_unit_id and u.owner_id=x.owner_id
   where x.owner_id=new.owner_id and x.invoice_item_id=new.invoice_item_id and u.product_id=new.product_id and u.status='in_stock'
   order by u.created_at,u.id limit new.quantity for update of u
  )
  update public.erp_product_units u set status='returned' from picked p where u.id=p.id and u.owner_id=new.owner_id and u.status='in_stock';
 end if;
 get diagnostics v_changed = row_count;
 if v_changed<>new.quantity then raise exception 'تعذر تحديث أرقام IMEI للمرتجع؛ تم إلغاء العملية'; end if;
 return new;
end $$;
