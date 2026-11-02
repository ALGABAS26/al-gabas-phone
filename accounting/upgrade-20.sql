-- AL GABAS ERP — Upgrade 20: validated party ledger transaction RPC
-- Prepared for a separate Supabase staging project only.
-- DO NOT execute against the live Supabase project in this stage.
--
-- This replaces the party-ledger form's direct INSERT only.
-- Existing invoice, purchase, sale, and return ledger posting RPCs are unchanged.

begin;

create or replace function public.erp_create_party_transaction(
  p_party_id uuid,
  p_transaction_date date,
  p_direction text,
  p_amount numeric,
  p_description text
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

  if p_party_id is null then
    raise exception 'يجب اختيار العميل أو المورد';
  end if;

  if p_transaction_date is null then
    raise exception 'تاريخ الحركة مطلوب';
  end if;

  if p_direction is null or p_direction not in ('increase','decrease') then
    raise exception 'نوع حركة الحساب غير صحيح';
  end if;

  if p_amount is null or p_amount <= 0
     or p_amount::text in ('NaN','Infinity','-Infinity') then
    raise exception 'مبلغ الحركة يجب أن يكون رقمًا موجبًا وصحيحًا';
  end if;

  if v_description is null then
    raise exception 'بيان الحركة مطلوب';
  end if;

  -- Verify and lock the parent party under the caller's owner RLS context.
  perform 1
  from public.erp_parties
  where id = p_party_id and owner_id = v_owner
  for key share;

  if not found then
    raise exception 'العميل أو المورد غير موجود أو لا تملك صلاحية الوصول إليه';
  end if;

  insert into public.erp_party_transactions (
    owner_id, party_id, transaction_date, direction, amount, description
  )
  values (
    v_owner, p_party_id, p_transaction_date, p_direction, p_amount, v_description
  )
  returning id into v_id;

  return v_id;
end;
$function$;

revoke all on function public.erp_create_party_transaction(uuid,date,text,numeric,text)
  from public, anon;
grant execute on function public.erp_create_party_transaction(uuid,date,text,numeric,text)
  to authenticated;

commit;
