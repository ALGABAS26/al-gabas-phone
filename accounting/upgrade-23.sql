-- AL GABAS ERP — Upgrade 23: bind sold IMEI units to the exact sale line
-- Apply only in a separate staging project after upgrades 01–22.
-- This migration does not touch public.products, storefront policies, or app files.
-- It is intentionally not executed by this assistant.

-- Keep the exact selected unit IDs on the sale line as an auditable transaction result.
ALTER TABLE public.erp_sales_invoice_items
  ADD COLUMN IF NOT EXISTS imei_unit_ids uuid[];

COMMENT ON COLUMN public.erp_sales_invoice_items.imei_unit_ids IS
  'Exact IMEI unit UUIDs selected by the sale transaction; empty array for untracked products.';

-- Validate mapping rows against the exact invoice line and serial.
CREATE OR REPLACE FUNCTION public.erp_guard_sale_unit_link()
RETURNS trigger
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = pg_catalog, public, pg_temp
AS $func$
DECLARE
  v_line_owner uuid;
  v_line_product uuid;
  v_unit_owner uuid;
  v_unit_product uuid;
  v_unit_status text;
BEGIN
  SELECT owner_id, product_id
    INTO v_line_owner, v_line_product
  FROM public.erp_sales_invoice_items
  WHERE id = NEW.invoice_item_id
  FOR KEY SHARE;

  SELECT owner_id, product_id, status
    INTO v_unit_owner, v_unit_product, v_unit_status
  FROM public.erp_product_units
  WHERE id = NEW.product_unit_id
  FOR KEY SHARE;

  IF v_line_owner IS NULL OR v_unit_owner IS NULL
     OR v_line_owner IS DISTINCT FROM NEW.owner_id
     OR v_unit_owner IS DISTINCT FROM NEW.owner_id
     OR v_line_product IS DISTINCT FROM v_unit_product
     OR v_unit_status IS DISTINCT FROM 'sold' THEN
    RAISE EXCEPTION 'ربط IMEI يجب أن يخص سطر بيع وجهازًا مباعًا من نفس الحساب والمنتج';
  END IF;

  RETURN NEW;
END;
$func$;

DROP TRIGGER IF EXISTS erp_sale_unit_link_guard
  ON public.erp_sales_invoice_item_units;
CREATE TRIGGER erp_sale_unit_link_guard
BEFORE INSERT OR UPDATE ON public.erp_sales_invoice_item_units
FOR EACH ROW EXECUTE FUNCTION public.erp_guard_sale_unit_link();

-- Replace the broad "oldest sold unlinked" selection with the exact IDs recorded
-- by the sale RPC. Tracked products cannot create a line without exact IDs.
CREATE OR REPLACE FUNCTION public.erp_link_sold_units_to_sale_line()
RETURNS trigger
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = pg_catalog, public, pg_temp
AS $func$
DECLARE
  v_tracked integer;
  v_valid integer;
  v_distinct integer;
  v_linked integer;
BEGIN
  SELECT count(*) INTO v_tracked
  FROM public.erp_product_units
  WHERE owner_id = NEW.owner_id AND product_id = NEW.product_id;

  IF v_tracked = 0 THEN
    IF COALESCE(cardinality(NEW.imei_unit_ids), 0) <> 0 THEN
      RAISE EXCEPTION 'سطر منتج غير متتبع لا يمكن ربطه بأرقام IMEI';
    END IF;
    RETURN NEW;
  END IF;

  IF NEW.imei_unit_ids IS NULL
     OR cardinality(NEW.imei_unit_ids) <> NEW.quantity THEN
    RAISE EXCEPTION 'لم يتم تمرير أرقام IMEI المحددة في عملية البيع؛ تم إلغاء الفاتورة';
  END IF;

  SELECT count(*), count(DISTINCT x.unit_id)
    INTO v_valid, v_distinct
  FROM unnest(NEW.imei_unit_ids) AS x(unit_id)
  JOIN public.erp_product_units u
    ON u.id = x.unit_id
   AND u.owner_id = NEW.owner_id
   AND u.product_id = NEW.product_id
   AND u.status = 'sold'
  WHERE NOT EXISTS (
    SELECT 1
    FROM public.erp_sales_invoice_item_units m
    WHERE m.owner_id = NEW.owner_id
      AND m.product_unit_id = x.unit_id
  );

  IF v_valid <> NEW.quantity OR v_distinct <> NEW.quantity THEN
    RAISE EXCEPTION 'أرقام IMEI المختارة غير مطابقة للمنتج أو سبق ربطها؛ تم إلغاء الفاتورة';
  END IF;

  INSERT INTO public.erp_sales_invoice_item_units
    (owner_id, invoice_item_id, product_unit_id)
  SELECT NEW.owner_id, NEW.id, x.unit_id
  FROM unnest(NEW.imei_unit_ids) AS x(unit_id);

  GET DIAGNOSTICS v_linked = ROW_COUNT;
  IF v_linked <> NEW.quantity THEN
    RAISE EXCEPTION 'تعذر ربط كل أرقام IMEI بسطر البيع؛ تم إلغاء العملية';
  END IF;

  RETURN NEW;
END;
$func$;

-- Rebuild the existing sale RPC without changing its signature or accounting
-- side effects. Exact unit IDs are captured from the UPDATE ... RETURNING set.
CREATE OR REPLACE FUNCTION public.erp_create_sale(
  p_invoice_no text,
  p_invoice_date date,
  p_customer_name text,
  p_customer_phone text,
  p_discount numeric,
  p_notes text,
  p_items jsonb,
  p_payments jsonb
) RETURNS uuid
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = pg_catalog, public, pg_temp
AS $func$
DECLARE
  v_owner uuid := auth.uid();
  v_invoice uuid;
  v_subtotal numeric(14,2) := 0;
  v_total numeric(14,2);
  v_paid numeric(14,2) := 0;
  v_item jsonb;
  v_payment jsonb;
  v_product public.erp_products%ROWTYPE;
  v_qty integer;
  v_price numeric(14,2);
  v_units integer;
  v_account text;
  v_amount numeric(14,2);
  v_payment_id uuid;
  v_selected_unit_ids uuid[];
BEGIN
  IF v_owner IS NULL THEN
    RAISE EXCEPTION 'يجب تسجيل الدخول';
  END IF;
  IF COALESCE(trim(p_invoice_no), '') = '' THEN
    RAISE EXCEPTION 'رقم الفاتورة مطلوب';
  END IF;
  IF p_items IS NULL OR jsonb_typeof(p_items) IS DISTINCT FROM 'array'
     OR jsonb_array_length(p_items) = 0 THEN
    RAISE EXCEPTION 'أضف منتجًا واحدًا على الأقل';
  END IF;
  IF p_payments IS NULL OR jsonb_typeof(p_payments) IS DISTINCT FROM 'array' THEN
    RAISE EXCEPTION 'بيانات التحصيل غير صحيحة';
  END IF;
  IF p_discount IS NOT NULL AND
     (p_discount::text IN ('NaN','Infinity','-Infinity') OR p_discount < 0) THEN
    RAISE EXCEPTION 'الخصم غير صحيح';
  END IF;

  -- Validate JSON objects and scalar fields before any casts or writes.
  IF EXISTS (
    SELECT 1
    FROM jsonb_array_elements(p_items) AS a(value)
    WHERE jsonb_typeof(a.value) IS DISTINCT FROM 'object'
       OR COALESCE(a.value->>'product_id','') !~
          '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
       OR COALESCE(a.value->>'quantity','') !~ '^[1-9][0-9]*$'
       OR COALESCE(a.value->>'unit_price','') !~ '^[0-9]+([.][0-9]+)?$'
  ) THEN
    RAISE EXCEPTION 'بيانات صنف البيع غير مكتملة أو غير صحيحة';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM jsonb_array_elements(p_payments) AS a(value)
    WHERE jsonb_typeof(a.value) IS DISTINCT FROM 'object'
       OR COALESCE(a.value->>'account_code','') NOT IN
          ('drawer','vodafone_cash','instapay')
       OR COALESCE(a.value->>'amount','') !~ '^[0-9]+([.][0-9]+)?$'
  ) THEN
    RAISE EXCEPTION 'بيانات التحصيل غير مكتملة أو غير صحيحة';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM jsonb_array_elements(p_items) WITH ORDINALITY a(value,n),
         jsonb_array_elements(p_items) WITH ORDINALITY b(value,n)
    WHERE a.n < b.n AND a.value->>'product_id' = b.value->>'product_id'
  ) THEN
    RAISE EXCEPTION 'لا تكرر نفس المنتج في سطرين؛ اجمع الكمية في سطر واحد';
  END IF;

  -- Lock products and validate stock before creating the invoice.
  FOR v_item IN SELECT value FROM jsonb_array_elements(p_items)
  LOOP
    v_qty := (v_item->>'quantity')::integer;
    v_price := (v_item->>'unit_price')::numeric;
    IF v_price::text IN ('NaN','Infinity','-Infinity') OR v_price < 0 THEN
      RAISE EXCEPTION 'الكمية أو السعر غير صحيح';
    END IF;

    SELECT * INTO v_product
    FROM public.erp_products
    WHERE id = (v_item->>'product_id')::uuid
      AND owner_id = v_owner
    FOR UPDATE;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'أحد المنتجات غير موجود';
    END IF;
    IF v_product.quantity < v_qty THEN
      RAISE EXCEPTION 'الكمية غير كافية للمنتج: % (المتاح %)',
        v_product.name, v_product.quantity;
    END IF;

    SELECT count(*) INTO v_units
    FROM public.erp_product_units
    WHERE owner_id = v_owner AND product_id = v_product.id;

    IF v_units > 0 AND (
      SELECT count(*) FROM public.erp_product_units
      WHERE owner_id = v_owner AND product_id = v_product.id
        AND status = 'in_stock'
    ) < v_qty THEN
      RAISE EXCEPTION 'أجهزة IMEI المتاحة غير كافية للمنتج: %', v_product.name;
    END IF;

    v_subtotal := v_subtotal + (v_qty * v_price);
  END LOOP;

  IF COALESCE(p_discount,0) > v_subtotal THEN
    RAISE EXCEPTION 'الخصم أكبر من إجمالي الفاتورة';
  END IF;
  v_total := v_subtotal - COALESCE(p_discount,0);

  FOR v_payment IN SELECT value FROM jsonb_array_elements(p_payments)
  LOOP
    v_account := v_payment->>'account_code';
    v_amount := (v_payment->>'amount')::numeric;
    IF v_amount::text IN ('NaN','Infinity','-Infinity') OR v_amount < 0 THEN
      RAISE EXCEPTION 'طريقة التحصيل غير صحيحة';
    END IF;
    IF v_amount > 0 THEN
      v_paid := v_paid + v_amount;
    END IF;
  END LOOP;

  IF v_paid > v_total THEN
    RAISE EXCEPTION 'إجمالي التحصيل أكبر من قيمة الفاتورة';
  END IF;

  INSERT INTO public.erp_sales_invoices
    (owner_id,invoice_no,invoice_date,customer_name,customer_phone,
     subtotal,discount,total,paid,notes)
  VALUES
    (v_owner,trim(p_invoice_no),COALESCE(p_invoice_date,current_date),
     COALESCE(nullif(trim(p_customer_name),''),'عميل نقدي'),
     nullif(trim(p_customer_phone),''),v_subtotal,COALESCE(p_discount,0),
     v_total,v_paid,nullif(trim(p_notes),''))
  RETURNING id INTO v_invoice;

  FOR v_item IN SELECT value FROM jsonb_array_elements(p_items)
  LOOP
    v_qty := (v_item->>'quantity')::integer;
    v_price := (v_item->>'unit_price')::numeric;

    SELECT * INTO v_product
    FROM public.erp_products
    WHERE id = (v_item->>'product_id')::uuid
      AND owner_id = v_owner
    FOR UPDATE;

    UPDATE public.erp_products
    SET quantity = quantity - v_qty, updated_at = now()
    WHERE id = v_product.id AND owner_id = v_owner;

    SELECT count(*) INTO v_units
    FROM public.erp_product_units
    WHERE owner_id = v_owner AND product_id = v_product.id;

    v_selected_unit_ids := ARRAY[]::uuid[];
    IF v_units > 0 THEN
      WITH picked AS (
        SELECT id
        FROM public.erp_product_units
        WHERE owner_id = v_owner
          AND product_id = v_product.id
          AND status = 'in_stock'
        ORDER BY created_at,id
        LIMIT v_qty
        FOR UPDATE
      ),
      changed AS (
        UPDATE public.erp_product_units u
        SET status = 'sold'
        FROM picked p
        WHERE u.id = p.id
          AND u.owner_id = v_owner
          AND u.product_id = v_product.id
          AND u.status = 'in_stock'
        RETURNING u.id
      )
      SELECT COALESCE(array_agg(id ORDER BY id), ARRAY[]::uuid[])
      INTO v_selected_unit_ids
      FROM changed;

      IF cardinality(v_selected_unit_ids) <> v_qty THEN
        RAISE EXCEPTION 'تعذر حجز أرقام IMEI المطلوبة؛ تم إلغاء الفاتورة';
      END IF;
    END IF;

    INSERT INTO public.erp_sales_invoice_items
      (owner_id,invoice_id,product_id,product_name,quantity,
       unit_price,unit_cost,line_total,imei_unit_ids)
    VALUES
      (v_owner,v_invoice,v_product.id,v_product.name,v_qty,
       v_price,v_product.cost_price,v_qty*v_price,v_selected_unit_ids);
  END LOOP;

  FOR v_payment IN SELECT value FROM jsonb_array_elements(p_payments)
  LOOP
    v_account := v_payment->>'account_code';
    v_amount := (v_payment->>'amount')::numeric;
    IF v_amount > 0 THEN
      INSERT INTO public.erp_sales_payments
        (owner_id,invoice_id,account_code,amount)
      VALUES (v_owner,v_invoice,v_account,v_amount)
      RETURNING id INTO v_payment_id;

      INSERT INTO public.erp_cash_movements
        (owner_id,movement_date,direction,amount,description,
         source_type,source_id,account_code)
      VALUES
        (v_owner,COALESCE(p_invoice_date,current_date),'in',v_amount,
         'تحصيل فاتورة مبيعات رقم '||trim(p_invoice_no),
         'sale_payment',v_payment_id,v_account);
    END IF;
  END LOOP;

  RETURN v_invoice;
END;
$func$;

REVOKE ALL ON FUNCTION public.erp_create_sale(text,date,text,text,numeric,text,jsonb,jsonb)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.erp_create_sale(text,date,text,text,numeric,text,jsonb,jsonb)
  TO authenticated;

-- Existing direct invoice-line inserts for tracked products now fail closed
-- unless exact unit IDs are supplied. Do not backfill historical invoices:
-- legacy associations are ambiguous and must remain untouched.
