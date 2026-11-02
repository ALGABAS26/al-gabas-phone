-- AL GABAS STORE ERP - Upgrade 10: cash balance protection and serial-aware returns
-- Run only after upgrades 08 and 09, after reviewing the complete migration set.
-- ERP-only safeguards. Does not touch storefront public.products.

-- Prevent cash balances from becoming negative, including concurrent outflows.
create or replace function public.erp_guard_cash_movement_balance()
returns trigger language plpgsql security invoker set search_path=public as $$
declare
 v_old_opening numeric(14,2); v_new_opening numeric(14,2);
 v_old_net numeric(14,2); v_new_net numeric(14,2);
 v_old_after numeric(14,2); v_new_after numeric(14,2);
 v_delta numeric(14,2);
begin
 if tg_op='INSERT' then
  select opening_balance into v_new_opening from public.erp_cash_accounts
   where owner_id=new.owner_id and account_code=new.account_code for update;
  if not found then raise exception 'حساب الخزنة غير مهيأ'; end if;
  select coalesce(sum(case when direction='in' then amount else -amount end),0)
   into v_new_net from public.erp_cash_movements
   where owner_id=new.owner_id and account_code=new.account_code;
  v_new_after:=coalesce(v_new_opening,0)+v_new_net;
  v_delta:=case when new.direction='in' then new.amount else -new.amount end;
  if v_new_after+v_delta<0 then
   raise exception 'الرصيد غير كافٍ في الحساب. الرصيد المتاح: %',v_new_after;
  end if;
  return new;
 end if;

 -- Lock both affected account rows in a stable order for UPDATE/DELETE.
 perform 1 from public.erp_cash_accounts
  where (owner_id=old.owner_id and account_code=old.account_code)
     or (tg_op='UPDATE' and owner_id=new.owner_id and account_code=new.account_code)
  order by owner_id,account_code for update;

 select opening_balance into v_old_opening from public.erp_cash_accounts
  where owner_id=old.owner_id and account_code=old.account_code;
 if not found then raise exception 'حساب الخزنة الأصلي غير مهيأ'; end if;
 select coalesce(sum(case when direction='in' then amount else -amount end),0)
  into v_old_net from public.erp_cash_movements
  where owner_id=old.owner_id and account_code=old.account_code and id<>old.id;
 v_old_after:=coalesce(v_old_opening,0)+v_old_net;
 if v_old_after<0 then
  raise exception 'لا يمكن تعديل أو حذف الحركة؛ سيصبح رصيد الحساب الأصلي سالبًا';
 end if;
 if tg_op='DELETE' then return old; end if;

 select opening_balance into v_new_opening from public.erp_cash_accounts
  where owner_id=new.owner_id and account_code=new.account_code;
 if not found then raise exception 'حساب الخزنة الجديد غير مهيأ'; end if;
 select coalesce(sum(case when direction='in' then amount else -amount end),0)
  into v_new_net from public.erp_cash_movements
  where owner_id=new.owner_id and account_code=new.account_code and id<>old.id;
 v_new_after:=coalesce(v_new_opening,0)+v_new_net;
 v_delta:=case when new.direction='in' then new.amount else -new.amount end;
 if v_new_after+v_delta<0 then
  raise exception 'الرصيد غير كافٍ في الحساب. الرصيد المتاح: %',v_new_after;
 end if;
 return new;
end $$;
drop trigger if exists erp_cash_movement_balance_guard on public.erp_cash_movements;
create trigger erp_cash_movement_balance_guard
before insert or update on public.erp_cash_movements
for each row execute function public.erp_guard_cash_movement_balance();

-- Opening balance edits must not make a cash account negative after its movement history.
create or replace function public.erp_guard_cash_opening_balance()
returns trigger language plpgsql security invoker set search_path=public as $$
declare v_net numeric(14,2);
begin
 if new.opening_balance<0 then raise exception 'الرصيد الافتتاحي لا يمكن أن يكون سالبًا'; end if;
 perform 1 from public.erp_cash_accounts where id=old.id for update;
 select coalesce(sum(case when direction='in' then amount else -amount end),0)
 into v_net from public.erp_cash_movements
 where owner_id=old.owner_id and account_code=old.account_code;
 if new.opening_balance+v_net<0 then
  raise exception 'لا يمكن تخفيض الرصيد الافتتاحي؛ سيصبح رصيد الحساب سالبًا';
 end if;
 return new;
end $$;
drop trigger if exists erp_cash_opening_balance_guard on public.erp_cash_accounts;
create trigger erp_cash_opening_balance_guard
before update of opening_balance on public.erp_cash_accounts
for each row execute function public.erp_guard_cash_opening_balance();

-- Until sold/purchased IMEI serials are linked to exact invoice lines, block ambiguous
-- returns of tracked products rather than corrupting serial availability and stock counts.
create or replace function public.erp_guard_imei_return()
returns trigger language plpgsql security invoker set search_path=public as $$
begin
 if exists(select 1 from public.erp_product_units
           where owner_id=new.owner_id and product_id=new.product_id) then
  raise exception 'مرتجع هذا المنتج يحتاج تحديد رقم IMEI الأصلي. أوقفنا المرتجع لحماية سجل الأجهزة؛ أضف دعم مرتجعات IMEI أولًا';
 end if;
 return new;
end $$;
drop trigger if exists erp_return_imei_guard on public.erp_return_items;
create trigger erp_return_imei_guard
before insert or update of product_id,owner_id on public.erp_return_items
for each row execute function public.erp_guard_imei_return();

-- Include the transfer ledger in standard backup exports in app.js.
