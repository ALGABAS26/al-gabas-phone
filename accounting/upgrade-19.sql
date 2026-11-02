-- AL GABAS ERP — Upgrade 19: validated customer/supplier creation RPC
-- Prepared for a separate Supabase staging project only.
-- DO NOT execute against the live Supabase project in this stage.
--
-- This replaces only the direct INSERT used by the party creation form.
-- Party ledger transactions remain a separate workflow and are not changed.

begin;

create or replace function public.erp_create_party(
  p_party_type text,
  p_name text,
  p_phone text default null,
  p_address text default null,
  p_opening_balance numeric default 0,
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
  v_name text := nullif(btrim(p_name), '');
  v_phone text := nullif(btrim(p_phone), '');
  v_address text := nullif(btrim(p_address), '');
  v_notes text := nullif(btrim(p_notes), '');
begin
  if v_owner is null then
    raise exception 'يجب تسجيل الدخول';
  end if;

  if p_party_type is null or p_party_type not in ('customer','supplier') then
    raise exception 'نوع الطرف غير صحيح';
  end if;

  if v_name is null then
    raise exception 'اسم العميل أو المورد مطلوب';
  end if;

  if p_opening_balance is null
     or p_opening_balance < 0
     or p_opening_balance::text in ('NaN','Infinity','-Infinity') then
    raise exception 'الرصيد الافتتاحي يجب أن يكون صفرًا أو رقمًا موجبًا وصحيحًا';
  end if;

  insert into public.erp_parties (
    owner_id, party_type, name, phone, address, opening_balance, notes
  )
  values (
    v_owner, p_party_type, v_name, v_phone, v_address, p_opening_balance, v_notes
  )
  returning id into v_id;

  return v_id;
end;
$function$;

revoke all on function public.erp_create_party(text,text,text,text,numeric,text)
  from public, anon;
grant execute on function public.erp_create_party(text,text,text,text,numeric,text)
  to authenticated;

commit;
