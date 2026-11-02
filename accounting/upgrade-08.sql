-- AL GABAS STORE: inventory counts and returns
create table if not exists public.erp_stock_counts (
 id uuid primary key default gen_random_uuid(), owner_id uuid not null references auth.users(id) on delete cascade,
 count_date date not null default current_date, notes text, status text not null default 'posted' check(status in ('posted')),
 created_at timestamptz not null default now()
);
create table if not exists public.erp_stock_count_items (
 id uuid primary key default gen_random_uuid(), owner_id uuid not null references auth.users(id) on delete cascade,
 count_id uuid not null references public.erp_stock_counts(id) on delete cascade,
 product_id uuid not null references public.erp_products(id), product_name text not null,
 system_quantity integer not null, counted_quantity integer not null,
 difference integer not null
);
create table if not exists public.erp_returns (
 id uuid primary key default gen_random_uuid(), owner_id uuid not null references auth.users(id) on delete cascade,
 return_no text not null, return_type text not null check(return_type in ('sale','purchase')),
 return_date date not null default current_date, invoice_id uuid not null,
 party_id uuid references public.erp_parties(id) on delete set null, party_name text not null default '',
 total numeric(14,2) not null check(total>=0), refunded numeric(14,2) not null default 0 check(refunded>=0),
 notes text, created_at timestamptz not null default now(), unique(owner_id,return_no)
);
create table if not exists public.erp_return_items (
 id uuid primary key default gen_random_uuid(), owner_id uuid not null references auth.users(id) on delete cascade,
 return_id uuid not null references public.erp_returns(id) on delete cascade,
 invoice_item_id uuid not null, product_id uuid not null references public.erp_products(id), product_name text not null,
 quantity integer not null check(quantity>0), unit_price numeric(14,2) not null check(unit_price>=0),
 unit_cost numeric(14,2) not null default 0 check(unit_cost>=0), line_total numeric(14,2) not null check(line_total>=0)
);
alter table public.erp_return_items add column if not exists unit_cost numeric(14,2) not null default 0 check(unit_cost>=0);
alter table public.erp_return_items add column if not exists invoice_item_id uuid;
create index if not exists erp_return_items_invoice_item_idx on public.erp_return_items(owner_id,invoice_item_id);
alter table public.erp_stock_counts enable row level security;
alter table public.erp_stock_count_items enable row level security;
alter table public.erp_returns enable row level security;
alter table public.erp_return_items enable row level security;
drop policy if exists erp_stock_counts_owner_all on public.erp_stock_counts;
create policy erp_stock_counts_owner_all on public.erp_stock_counts for all to authenticated using(owner_id=auth.uid()) with check(owner_id=auth.uid());
drop policy if exists erp_stock_count_items_owner_all on public.erp_stock_count_items;
create policy erp_stock_count_items_owner_all on public.erp_stock_count_items for all to authenticated using(owner_id=auth.uid()) with check(owner_id=auth.uid());
drop policy if exists erp_returns_owner_all on public.erp_returns;
create policy erp_returns_owner_all on public.erp_returns for all to authenticated using(owner_id=auth.uid()) with check(owner_id=auth.uid());
drop policy if exists erp_return_items_owner_all on public.erp_return_items;
create policy erp_return_items_owner_all on public.erp_return_items for all to authenticated using(owner_id=auth.uid()) with check(owner_id=auth.uid());
grant select,insert,update,delete on public.erp_stock_counts,public.erp_stock_count_items,public.erp_returns,public.erp_return_items to authenticated;

create or replace function public.erp_post_stock_count(p_count_date date,p_notes text,p_items jsonb)
returns uuid language plpgsql security invoker set search_path=public as $$
declare v_owner uuid:=auth.uid(); v_count uuid; v_item jsonb; v_product public.erp_products%rowtype;
 v_counted integer; v_diff integer;
begin
 if v_owner is null then raise exception 'يجب تسجيل الدخول'; end if;
 if jsonb_typeof(p_items)<>'array' or jsonb_array_length(p_items)=0 then raise exception 'لا توجد أصناف للجرد'; end if;
 if exists(select 1 from jsonb_array_elements(p_items) with ordinality a(value,n), jsonb_array_elements(p_items) with ordinality b(value,n) where a.n<b.n and a.value->>'product_id'=b.value->>'product_id') then raise exception 'لا تكرر المنتج في الجرد'; end if;
 insert into public.erp_stock_counts(owner_id,count_date,notes) values(v_owner,coalesce(p_count_date,current_date),nullif(trim(p_notes),'')) returning id into v_count;
 for v_item in select value from jsonb_array_elements(p_items) loop
  select * into v_product from public.erp_products where id=(v_item->>'product_id')::uuid and owner_id=v_owner for update;
  if not found then raise exception 'منتج غير موجود'; end if;
  v_counted:=(v_item->>'counted_quantity')::integer;
  if v_counted<0 then raise exception 'الكمية الفعلية لا يمكن أن تكون سالبة'; end if;
  if exists(select 1 from public.erp_product_units where owner_id=v_owner and product_id=v_product.id)
     and v_counted<>(select count(*) from public.erp_product_units where owner_id=v_owner and product_id=v_product.id and status='in_stock') then
    raise exception 'هذا المنتج له أرقام IMEI؛ يجب أن تطابق كمية الجرد عدد الأجهزة المسجلة بحالة متاح';
  end if;
  v_diff:=v_counted-v_product.quantity;
  insert into public.erp_stock_count_items(owner_id,count_id,product_id,product_name,system_quantity,counted_quantity,difference)
  values(v_owner,v_count,v_product.id,v_product.name,v_product.quantity,v_counted,v_diff);
  update public.erp_products set quantity=v_counted,updated_at=now() where id=v_product.id and owner_id=v_owner;
 end loop;
 return v_count;
end $$;
grant execute on function public.erp_post_stock_count(date,text,jsonb) to authenticated;

create or replace function public.erp_post_return(
 p_return_no text,p_return_type text,p_invoice_id uuid,p_return_date date,p_notes text,p_items jsonb,p_refund_payments jsonb
) returns uuid language plpgsql security invoker set search_path=public as $$
declare v_owner uuid:=auth.uid(); v_return uuid; v_party uuid; v_party_name text:=''; v_invoice_no text;
 v_item jsonb; v_product public.erp_products%rowtype; v_orig record; v_qty integer; v_price numeric(14,2); v_cost numeric(14,2);
 v_total numeric(14,2):=0; v_refunded numeric(14,2):=0; v_pay jsonb; v_account text; v_amount numeric(14,2); v_pid uuid;
begin
 if v_owner is null then raise exception 'يجب تسجيل الدخول'; end if;
 if p_return_type not in ('sale','purchase') then raise exception 'نوع المرتجع غير صحيح'; end if;
 if coalesce(trim(p_return_no),'')='' then raise exception 'رقم المرتجع مطلوب'; end if;
 if jsonb_typeof(p_items)<>'array' or jsonb_array_length(p_items)=0 then raise exception 'أضف صنفًا واحدًا على الأقل'; end if;
 if exists(select 1 from jsonb_array_elements(p_items) with ordinality a(value,n), jsonb_array_elements(p_items) with ordinality b(value,n) where a.n<b.n and a.value->>'invoice_item_id'=b.value->>'invoice_item_id') then raise exception 'لا تكرر نفس سطر الفاتورة في المرتجع'; end if;
 if p_return_type='sale' then
  select customer_name into v_party_name from public.erp_sales_invoices where id=p_invoice_id and owner_id=v_owner and status='completed' for update;
  if not found then raise exception 'فاتورة البيع غير موجودة أو ملغاة'; end if;
 else
  select supplier_id,supplier_name into v_party,v_party_name from public.erp_purchase_invoices where id=p_invoice_id and owner_id=v_owner for update;
  if not found then raise exception 'فاتورة الشراء غير موجودة'; end if;
 end if;
 for v_item in select value from jsonb_array_elements(p_items) loop
  v_qty:=(v_item->>'quantity')::integer;
  if v_qty<=0 then raise exception 'كمية المرتجع غير صحيحة'; end if;
  if p_return_type='sale' then
   select product_id,product_name,quantity,unit_price into v_orig from public.erp_sales_invoice_items where id=(v_item->>'invoice_item_id')::uuid and invoice_id=p_invoice_id and owner_id=v_owner;
  else
   select product_id,product_name,quantity,unit_cost as unit_price into v_orig from public.erp_purchase_invoice_items where id=(v_item->>'invoice_item_id')::uuid and invoice_id=p_invoice_id and owner_id=v_owner;
  end if;
  if not found then raise exception 'صنف غير تابع للفاتورة المحددة'; end if;
  if v_qty>(v_orig.quantity - coalesce((select sum(ri.quantity) from public.erp_return_items ri join public.erp_returns rr on rr.id=ri.return_id where rr.invoice_id=p_invoice_id and rr.return_type=p_return_type and rr.owner_id=v_owner and ri.invoice_item_id=(v_item->>'invoice_item_id')::uuid),0)) then raise exception 'كمية المرتجع أكبر من الكمية المتبقية للمرتجع'; end if;
  v_price:=v_orig.unit_price;
  v_cost:=case when p_return_type='sale' then coalesce((select unit_cost from public.erp_sales_invoice_items where id=(v_item->>'invoice_item_id')::uuid and invoice_id=p_invoice_id and owner_id=v_owner),0) else v_orig.unit_price end;
  v_total:=v_total+(v_qty*v_price);
 end loop;
 if p_return_type='sale' then
  if jsonb_typeof(p_refund_payments)<>'array' then raise exception 'بيانات رد المبلغ غير صحيحة'; end if;
  for v_pay in select value from jsonb_array_elements(p_refund_payments) loop
   v_account:=v_pay->>'account_code';v_amount:=(v_pay->>'amount')::numeric;
   if v_account not in ('drawer','vodafone_cash','instapay') or v_amount<0 then raise exception 'مصدر رد المبلغ غير صحيح'; end if;
   v_refunded:=v_refunded+v_amount;
  end loop;
  if v_refunded>v_total then raise exception 'المبلغ المرتجع أكبر من قيمة الأصناف'; end if;
 else
  v_refunded:=0;
 end if;
 insert into public.erp_returns(owner_id,return_no,return_type,return_date,invoice_id,party_id,party_name,total,refunded,notes)
 values(v_owner,trim(p_return_no),p_return_type,coalesce(p_return_date,current_date),p_invoice_id,v_party,coalesce(v_party_name,''),v_total,v_refunded,nullif(trim(p_notes),'')) returning id into v_return;
 for v_item in select value from jsonb_array_elements(p_items) loop
  v_qty:=(v_item->>'quantity')::integer;
  if p_return_type='sale' then
   select * into v_orig from public.erp_sales_invoice_items where id=(v_item->>'invoice_item_id')::uuid and invoice_id=p_invoice_id and owner_id=v_owner;
   update public.erp_products set quantity=quantity+v_qty,updated_at=now() where id=v_orig.product_id and owner_id=v_owner;
   -- Do not reactivate arbitrary IMEI units: the original sold serials are not linked to invoice lines.
  else
   select id,product_id,product_name,quantity,unit_cost as unit_price,unit_cost into v_orig from public.erp_purchase_invoice_items where id=(v_item->>'invoice_item_id')::uuid and invoice_id=p_invoice_id and owner_id=v_owner;
   update public.erp_products set quantity=quantity-v_qty,updated_at=now() where id=v_orig.product_id and owner_id=v_owner and quantity>=v_qty;
   if not found then raise exception 'المخزون الحالي لا يكفي لمرتجع الشراء'; end if;
  end if;
  v_cost:=coalesce(v_orig.unit_cost,0);
  insert into public.erp_return_items(owner_id,return_id,invoice_item_id,product_id,product_name,quantity,unit_price,unit_cost,line_total)
  values(v_owner,v_return,(v_item->>'invoice_item_id')::uuid,v_orig.product_id,v_orig.product_name,v_qty,v_orig.unit_price,v_cost,v_qty*v_orig.unit_price);
 end loop;
 if p_return_type='sale' then
  for v_pay in select value from jsonb_array_elements(p_refund_payments) loop
   v_account:=v_pay->>'account_code';v_amount:=(v_pay->>'amount')::numeric;
   if v_amount>0 then
    insert into public.erp_cash_movements(owner_id,movement_date,direction,amount,description,source_type,source_id,account_code)
    values(v_owner,coalesce(p_return_date,current_date),'out',v_amount,'رد مبلغ مرتجع بيع رقم '||trim(p_return_no),'sale_return',gen_random_uuid(),v_account);
   end if;
  end loop;
 else
  if v_party is not null and v_total>0 then
   insert into public.erp_party_transactions(owner_id,party_id,transaction_date,direction,amount,description)
   values(v_owner,v_party,coalesce(p_return_date,current_date),'decrease',v_total,'مرتجع مشتريات رقم '||trim(p_return_no));
  end if;
 end if;
 return v_return;
end $$;
grant execute on function public.erp_post_return(text,text,uuid,date,text,jsonb,jsonb) to authenticated;
