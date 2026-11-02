-- AL GABAS ERP — Upgrade 22: validated shop settings upsert RPC
-- Prepared for a separate Supabase staging project only.
-- DO NOT execute against the live Supabase project in this stage.
--
-- Replaces only the settings form's direct upsert. Reads and existing settings
-- table/RLS remain unchanged. Currency is intentionally limited to EGP,
-- matching the current table constraint.

begin;

create or replace function public.erp_save_shop_settings(
  p_shop_name text,
  p_shop_name_en text,
  p_phone text default null,
  p_address text default null,
  p_currency text default 'EGP',
  p_invoice_prefix text default 'AGP',
  p_invoice_note text default null
)
returns uuid
language plpgsql
security invoker
set search_path = pg_catalog, public
as $function$
declare
  v_owner uuid := auth.uid();
  v_id uuid;
  v_shop_name text := nullif(btrim(p_shop_name), '');
  v_shop_name_en text := nullif(btrim(p_shop_name_en), '');
  v_phone text := nullif(btrim(p_phone), '');
  v_address text := nullif(btrim(p_address), '');
  v_prefix text := coalesce(nullif(btrim(p_invoice_prefix), ''), 'AGP');
  v_note text := nullif(btrim(p_invoice_note), '');
begin
  if v_owner is null then
    raise exception 'يجب تسجيل الدخول';
  end if;

  if v_shop_name is null then
    raise exception 'اسم المحل بالعربية مطلوب';
  end if;
  if v_shop_name_en is null then
    raise exception 'اسم المحل بالإنجليزية مطلوب';
  end if;
  if p_currency is distinct from 'EGP' then
    raise exception 'العملة المدعومة حاليًا هي الجنيه المصري فقط';
  end if;

  insert into public.erp_shop_settings (
    owner_id, shop_name, shop_name_en, phone, address,
    currency, invoice_prefix, invoice_note, updated_at
  )
  values (
    v_owner, v_shop_name, v_shop_name_en, v_phone, v_address,
    'EGP', v_prefix, v_note, now()
  )
  on conflict (owner_id) do update
    set shop_name = excluded.shop_name,
        shop_name_en = excluded.shop_name_en,
        phone = excluded.phone,
        address = excluded.address,
        currency = excluded.currency,
        invoice_prefix = excluded.invoice_prefix,
        invoice_note = excluded.invoice_note,
        updated_at = now()
  returning id into v_id;

  return v_id;
end;
$function$;

revoke all on function public.erp_save_shop_settings(text,text,text,text,text,text,text)
  from public, anon;
grant execute on function public.erp_save_shop_settings(text,text,text,text,text,text,text)
  to authenticated;

commit;
