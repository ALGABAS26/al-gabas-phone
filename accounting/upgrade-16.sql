-- AL GABAS ERP — Upgrade 16: validated Fawry transaction creation RPC
-- Workflow: replace the browser's direct INSERT into erp_fawry_transactions.
--
-- Prepared for a separate Supabase staging project only.
-- DO NOT execute against the live Supabase project in this stage.
--
-- Compatibility:
--   * SECURITY INVOKER preserves the existing owner_id RLS boundary.
--   * owner_id is derived only from auth.uid(); it is not accepted from caller.
--   * No Fawry daily-close, cash-movement, or settlement behavior is changed.
--   * Existing authenticated table DML is preserved for remaining app workflows.
--   * No storefront objects or public.products permissions are touched.
--
-- Prerequisite: the existing ERP schema (accounting/schema.sql) and upgrades 02-15.

begin;

create or replace function public.erp_create_fawry_transaction(
  p_type text,
  p_amount numeric,
  p_commission numeric default 0,
  p_fee numeric default 0,
  p_reference text default null,
  p_status text default 'completed',
  p_notes text default null
)
returns uuid
language plpgsql
security invoker
set search_path = pg_catalog, public
as $function$
declare
  v_owner uuid := auth.uid();
  v_id uuid;
  v_reference text := nullif(btrim(p_reference), '');
  v_notes text := nullif(btrim(p_notes), '');
begin
  if v_owner is null then
    raise exception 'يجب تسجيل الدخول';
  end if;

  if p_type is null or p_type not in (
    'topup','service','withdrawal','settlement','fee','reversal'
  ) then
    raise exception 'نوع حركة فوري غير صحيح';
  end if;

  if p_amount is null or p_amount <= 0
     or p_amount::text in ('NaN','Infinity','-Infinity') then
    raise exception 'مبلغ حركة فوري يجب أن يكون رقمًا موجبًا وصحيحًا';
  end if;

  if p_commission is null or p_commission < 0
     or p_commission::text in ('NaN','Infinity','-Infinity') then
    raise exception 'العمولة غير صحيحة';
  end if;

  if p_fee is null or p_fee < 0
     or p_fee::text in ('NaN','Infinity','-Infinity') then
    raise exception 'الرسوم غير صحيحة';
  end if;

  if p_status is null or p_status not in ('completed','pending','failed') then
    raise exception 'حالة حركة فوري غير صحيحة';
  end if;

  insert into public.erp_fawry_transactions (
    owner_id, type, amount, commission, fee, reference, status, notes
  )
  values (
    v_owner, p_type, p_amount, p_commission, p_fee,
    v_reference, p_status, v_notes
  )
  returning id into v_id;

  return v_id;
end;
$function$;

-- Exact client-callable signature only. Do not alter table ACLs or default ACLs here.
revoke all on function public.erp_create_fawry_transaction(
  text, numeric, numeric, numeric, text, text, text
) from public, anon;

grant execute on function public.erp_create_fawry_transaction(
  text, numeric, numeric, numeric, text, text, text
) to authenticated;

commit;

-- No Fawry daily-close RPC, cash movement trigger, RLS policy, or storefront
-- permission is modified by this migration.
