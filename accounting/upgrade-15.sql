-- AL GABAS ERP — Upgrade 15: first direct-write RPC replacement
-- Workflow: create product + optional IMEI unit atomically.
--
-- DESIGN / REVIEW STATUS:
--   Prepared for a separate Supabase test project only.
--   DO NOT execute against the live Supabase project in this stage.
--
-- Compatibility:
--   * SECURITY INVOKER preserves the current owner_id RLS boundary.
--   * owner_id is derived exclusively from auth.uid(); no client owner_id is accepted.
--   * Existing authenticated table DML grants are intentionally NOT revoked here.
--   * This does not change any storefront object, public.products, or its policies.
--   * Product and optional serial unit are inserted in one function call/transaction.
--
-- Prerequisites: upgrades 01-14 in their documented order, including
-- public.erp_imei_luhn_valid(text) from upgrade-12.sql.

begin;

create or replace function public.erp_create_product_with_optional_imei(
  p_name text,
  p_category text,
  p_condition text,
  p_cost_price numeric,
  p_sale_price numeric,
  p_quantity integer,
  p_barcode text,
  p_imei1 text default null,
  p_imei2 text default null
)
returns uuid
language plpgsql
security invoker
set search_path = pg_catalog, public
as $function$
declare
  v_owner uuid := auth.uid();
  v_product_id uuid;
  v_name text := nullif(btrim(p_name), '');
  v_category text := nullif(btrim(p_category), '');
  v_barcode text := nullif(btrim(p_barcode), '');
  v_imei1 text := nullif(btrim(p_imei1), '');
  v_imei2 text := nullif(btrim(p_imei2), '');
begin
  if v_owner is null then
    raise exception 'يجب تسجيل الدخول';
  end if;

  if v_name is null then
    raise exception 'اسم المنتج مطلوب';
  end if;
  if v_category is null then
    raise exception 'تصنيف المنتج مطلوب';
  end if;
  if p_condition is null or p_condition not in ('new','used','accessory') then
    raise exception 'حالة المنتج غير صحيحة';
  end if;
  if p_cost_price is null or p_cost_price < 0
     or p_cost_price::text in ('NaN','Infinity','-Infinity') then
    raise exception 'سعر التكلفة غير صحيح';
  end if;
  if p_sale_price is null or p_sale_price < 0
     or p_sale_price::text in ('NaN','Infinity','-Infinity') then
    raise exception 'سعر البيع غير صحيح';
  end if;
  if p_quantity is null or p_quantity < 0 then
    raise exception 'كمية المنتج غير صحيحة';
  end if;
  if v_barcode is null then
    raise exception 'باركود المنتج مطلوب';
  end if;

  if v_imei1 is not null and v_imei1 !~ '^[0-9]{15}$' then
    raise exception 'IMEI 1 يجب أن يتكون من 15 رقمًا';
  end if;
  if v_imei2 is not null and v_imei2 !~ '^[0-9]{15}$' then
    raise exception 'IMEI 2 يجب أن يتكون من 15 رقمًا';
  end if;
  if v_imei1 is not null and not public.erp_imei_luhn_valid(v_imei1) then
    raise exception 'IMEI 1 غير صحيح';
  end if;
  if v_imei2 is not null and not public.erp_imei_luhn_valid(v_imei2) then
    raise exception 'IMEI 2 غير صحيح';
  end if;
  if v_imei1 is not null and v_imei1 = v_imei2 then
    raise exception 'IMEI 1 وIMEI 2 لا يمكن أن يكونا متطابقين';
  end if;
  if (v_imei1 is not null or v_imei2 is not null) and p_quantity <> 1 then
    raise exception 'المنتج المتتبع برقم IMEI يجب أن تكون كميته 1';
  end if;

  insert into public.erp_products (
    owner_id, name, category, condition,
    cost_price, sale_price, quantity, barcode
  )
  values (
    v_owner, v_name, v_category, p_condition,
    p_cost_price, p_sale_price, p_quantity, v_barcode
  )
  returning id into v_product_id;

  if v_imei1 is not null or v_imei2 is not null then
    insert into public.erp_product_units (
      owner_id, product_id, imei1, imei2,
      unit_barcode, purchase_price, status
    )
    values (
      v_owner, v_product_id, v_imei1, v_imei2,
      v_barcode || '-01', p_cost_price, 'in_stock'
    );
  end if;

  return v_product_id;
end;
$function$;

-- Treat this as a client-callable RPC, not a trigger/helper function.
-- Exact signature only; no broad function ACL changes in this migration.
revoke all on function public.erp_create_product_with_optional_imei(
  text, text, text, numeric, numeric, integer, text, text, text
) from public, anon;

grant execute on function public.erp_create_product_with_optional_imei(
  text, text, text, numeric, numeric, integer, text, text, text
) to authenticated;

commit;

-- No table grants, default privileges, RLS policies, triggers, or storefront
-- permissions are changed by this migration.
