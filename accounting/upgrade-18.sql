-- AL GABAS ERP — Upgrade 18: validated manual cash movement RPC
-- Prepared for a separate Supabase staging project only.
-- DO NOT execute against the live Supabase project in this stage.
--
-- The existing cash movement balance trigger remains responsible for locking
-- the cash account and preventing negative balances under concurrent writes.
-- This RPC does not modify trigger logic, transfers, Fawry top-ups, or other
-- source-linked accounting movements.

begin;

create or replace function public.erp_create_manual_cash_movement(
  p_movement_date date,
  p_direction text,
  p_amount numeric,
  p_description text,
  p_account_code text
)
returns uuid
language plpgsql
security invoker
set search_path = pg_catalog, public, pg_temp
as $function$
declare
  v_owner uuid := auth.uid();
  v_id uuid;
  v_description text := nullif(btrim(p_description), '');
begin
  if v_owner is null then
    raise exception 'يجب تسجيل الدخول';
  end if;

  if p_movement_date is null then
    raise exception 'تاريخ الحركة مطلوب';
  end if;

  if p_direction is null or p_direction not in ('in','out') then
    raise exception 'اتجاه حركة الخزنة غير صحيح';
  end if;

  if p_amount is null or p_amount <= 0
     or p_amount::text in ('NaN','Infinity','-Infinity') then
    raise exception 'مبلغ الحركة يجب أن يكون رقمًا موجبًا وصحيحًا';
  end if;

  if p_account_code is null
     or p_account_code not in ('drawer','vodafone_cash','instapay') then
    raise exception 'حساب الخزنة غير صحيح';
  end if;

  if v_description is null then
    raise exception 'وصف الحركة مطلوب';
  end if;

  insert into public.erp_cash_movements (
    owner_id, movement_date, direction, amount, description,
    source_type, source_id, account_code
  )
  values (
    v_owner, p_movement_date, p_direction, p_amount, v_description,
    'manual', gen_random_uuid(), p_account_code
  )
  returning id into v_id;

  return v_id;
end;
$function$;

revoke all on function public.erp_create_manual_cash_movement(date,text,numeric,text,text)
  from public, anon;
grant execute on function public.erp_create_manual_cash_movement(date,text,numeric,text,text)
  to authenticated;

commit;
