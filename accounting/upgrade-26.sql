-- AL GABAS ERP — Upgrade 26: NULL-safe expense, cash transfer, and purchase RPC validation
-- Apply only in a separate staging project after upgrades 01–25.
-- ERP-only: does not alter public.products, storefront code, or storefront policies.
-- This file is a draft and has NOT been executed by this assistant.

CREATE OR REPLACE FUNCTION public.erp_record_expense(
  p_expense_date date,
  p_category text,
  p_amount numeric,
  p_account_code text,
  p_description text
) RETURNS uuid
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = pg_catalog, public, pg_temp
AS $func$
DECLARE
  v_owner uuid := auth.uid();
  v_id uuid;
BEGIN
  IF v_owner IS NULL THEN
    RAISE EXCEPTION 'يجب تسجيل الدخول';
  END IF;
  IF p_category IS NULL OR btrim(p_category) = ''
     OR p_description IS NULL OR btrim(p_description) = '' THEN
    RAISE EXCEPTION 'نوع المصروف والبيان مطلوبان';
  END IF;
  IF p_amount IS NULL OR p_amount::text IN ('NaN','Infinity','-Infinity')
     OR p_amount <= 0 THEN
    RAISE EXCEPTION 'قيمة المصروف يجب أن تكون أكبر من صفر';
  END IF;
  IF p_account_code IS NULL OR p_account_code NOT IN
     ('drawer','vodafone_cash','instapay') THEN
    RAISE EXCEPTION 'حساب الدفع غير صحيح';
  END IF;

  INSERT INTO public.erp_expenses
    (owner_id,expense_date,category,description,amount,account_code)
  VALUES
    (v_owner,COALESCE(p_expense_date,current_date),btrim(p_category),
     btrim(p_description),p_amount,p_account_code)
  RETURNING id INTO v_id;

  INSERT INTO public.erp_cash_movements
    (owner_id,movement_date,direction,amount,description,source_type,source_id,account_code)
  VALUES
    (v_owner,COALESCE(p_expense_date,current_date),'out',p_amount,
     'مصروف: '||btrim(p_description),'expense',v_id,p_account_code);

  RETURN v_id;
END;
$func$;

REVOKE ALL ON FUNCTION public.erp_record_expense(date,text,numeric,text,text)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.erp_record_expense(date,text,numeric,text,text)
  TO authenticated;


CREATE OR REPLACE FUNCTION public.erp_transfer_cash(
  p_transfer_date date,
  p_from_account text,
  p_to_account text,
  p_amount numeric,
  p_notes text DEFAULT NULL
) RETURNS uuid
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = pg_catalog, public, pg_temp
AS $func$
DECLARE
  v_owner uuid := auth.uid();
  v_id uuid;
  v_from_balance numeric(14,2);
  v_from_opening numeric(14,2);
  v_transfer_date date := COALESCE(p_transfer_date,current_date);
BEGIN
  IF v_owner IS NULL THEN
    RAISE EXCEPTION 'يجب تسجيل الدخول';
  END IF;
  IF p_from_account IS NULL OR p_to_account IS NULL
     OR p_from_account NOT IN ('drawer','vodafone_cash','instapay')
     OR p_to_account NOT IN ('drawer','vodafone_cash','instapay') THEN
    RAISE EXCEPTION 'اختر حسابي تحويل صحيحين';
  END IF;
  IF p_from_account = p_to_account THEN
    RAISE EXCEPTION 'لا يمكن التحويل إلى نفس الحساب';
  END IF;
  IF p_amount IS NULL OR p_amount::text IN ('NaN','Infinity','-Infinity')
     OR p_amount <= 0 THEN
    RAISE EXCEPTION 'مبلغ التحويل يجب أن يكون أكبر من صفر';
  END IF;

  PERFORM public.erp_init_cash_accounts();

  -- Lock both account rows in stable order before reading the balance.
  PERFORM 1
  FROM public.erp_cash_accounts
  WHERE owner_id=v_owner
    AND account_code IN (p_from_account,p_to_account)
  ORDER BY account_code
  FOR UPDATE;

  SELECT opening_balance
    INTO v_from_opening
  FROM public.erp_cash_accounts
  WHERE owner_id=v_owner AND account_code=p_from_account
  FOR UPDATE;

  SELECT COALESCE(sum(CASE WHEN direction='in' THEN amount ELSE -amount END),0)
    INTO v_from_balance
  FROM public.erp_cash_movements
  WHERE owner_id=v_owner AND account_code=p_from_account;

  v_from_balance := COALESCE(v_from_opening,0) + COALESCE(v_from_balance,0);
  IF p_amount > v_from_balance THEN
    RAISE EXCEPTION 'الرصيد غير كافٍ في الحساب المحدد. الرصيد المتاح: %',
      v_from_balance;
  END IF;

  INSERT INTO public.erp_cash_transfers
    (owner_id,transfer_date,from_account,to_account,amount,notes)
  VALUES
    (v_owner,v_transfer_date,p_from_account,p_to_account,p_amount,
     NULLIF(btrim(p_notes),''))
  RETURNING id INTO v_id;

  INSERT INTO public.erp_cash_movements
    (owner_id,movement_date,direction,amount,description,source_type,source_id,account_code)
  VALUES
    (v_owner,v_transfer_date,'out',p_amount,
     'تحويل إلى '||
       CASE p_to_account
         WHEN 'drawer' THEN 'درج الكاش'
         WHEN 'vodafone_cash' THEN 'فودافون كاش'
         ELSE 'إنستا باي'
       END,
     'cash_transfer_out',v_id,p_from_account),
    (v_owner,v_transfer_date,'in',p_amount,
     'تحويل من '||
       CASE p_from_account
         WHEN 'drawer' THEN 'درج الكاش'
         WHEN 'vodafone_cash' THEN 'فودافون كاش'
         ELSE 'إنستا باي'
       END,
     'cash_transfer_in',v_id,p_to_account);

  RETURN v_id;
END;
$func$;

REVOKE ALL ON FUNCTION public.erp_transfer_cash(date,text,text,numeric,text)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.erp_transfer_cash(date,text,text,numeric,text)
  TO authenticated;


CREATE OR REPLACE FUNCTION public.erp_create_purchase(
  p_invoice_no text,
  p_invoice_date date,
  p_supplier_id uuid,
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
  v_product public.erp_products%rowtype;
  v_qty integer;
  v_cost numeric(14,2);
  v_account text;
  v_amount numeric(14,2);
  v_payment_id uuid;
  v_supplier_name text := 'مورد نقدي';
  v_new_cost numeric(14,2);
  v_invoice_item uuid;
  v_units jsonb;
  v_unit jsonb;
  v_imei1 text;
  v_imei2 text;
  v_unit_barcode text;
  v_tracked integer;
BEGIN
  IF v_owner IS NULL THEN
    RAISE EXCEPTION 'يجب تسجيل الدخول';
  END IF;
  IF p_invoice_no IS NULL OR btrim(p_invoice_no) = '' THEN
    RAISE EXCEPTION 'رقم الفاتورة مطلوب';
  END IF;
  IF p_items IS NULL OR jsonb_typeof(p_items) IS DISTINCT FROM 'array'
     OR jsonb_array_length(p_items) = 0 THEN
    RAISE EXCEPTION 'أضف صنفًا واحدًا على الأقل';
  END IF;
  IF p_payments IS NULL OR jsonb_typeof(p_payments) IS DISTINCT FROM 'array' THEN
    RAISE EXCEPTION 'بيانات الدفع غير صحيحة';
  END IF;
  IF p_discount IS NOT NULL AND
     (p_discount::text IN ('NaN','Infinity','-Infinity') OR p_discount < 0) THEN
    RAISE EXCEPTION 'الخصم غير صحيح';
  END IF;

  -- Validate every item before any UUID/integer/numeric cast or write.
  IF EXISTS (
    SELECT 1
    FROM jsonb_array_elements(p_items) AS a(value)
    WHERE jsonb_typeof(a.value) IS DISTINCT FROM 'object'
       OR COALESCE(a.value->>'product_id','') !~
          '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
       OR COALESCE(a.value->>'quantity','') !~ '^[1-9][0-9]*$'
       OR COALESCE(a.value->>'unit_cost','') !~ '^[0-9]+([.][0-9]+)?$'
       OR (a.value ? 'imei_units' AND
           jsonb_typeof(a.value->'imei_units') IS DISTINCT FROM 'array')
  ) THEN
    RAISE EXCEPTION 'بيانات أصناف فاتورة الشراء غير مكتملة أو غير صحيحة';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM jsonb_array_elements(p_items) AS a(value),
         jsonb_array_elements(COALESCE(a.value->'imei_units','[]'::jsonb)) AS u(value)
    WHERE jsonb_typeof(u.value) IS DISTINCT FROM 'object'
       OR (u.value ? 'imei1' AND jsonb_typeof(u.value->'imei1') NOT IN ('string','null'))
       OR (u.value ? 'imei2' AND jsonb_typeof(u.value->'imei2') NOT IN ('string','null'))
  ) THEN
    RAISE EXCEPTION 'بيانات أرقام IMEI غير صحيحة';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM jsonb_array_elements(p_payments) AS a(value)
    WHERE jsonb_typeof(a.value) IS DISTINCT FROM 'object'
       OR COALESCE(a.value->>'account_code','') NOT IN
          ('drawer','vodafone_cash','instapay')
       OR COALESCE(a.value->>'amount','') !~ '^[0-9]+([.][0-9]+)?$'
  ) THEN
    RAISE EXCEPTION 'بيانات الدفع غير مكتملة أو غير صحيحة';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM jsonb_array_elements(p_items) WITH ORDINALITY a(value,n),
         jsonb_array_elements(p_items) WITH ORDINALITY b(value,n)
    WHERE a.n < b.n AND a.value->>'product_id' = b.value->>'product_id'
  ) THEN
    RAISE EXCEPTION 'لا تكرر نفس المنتج في سطرين؛ اجمع الكمية في سطر واحد';
  END IF;

  IF p_supplier_id IS NOT NULL THEN
    SELECT name INTO v_supplier_name
    FROM public.erp_parties
    WHERE id=p_supplier_id AND owner_id=v_owner AND party_type='supplier'
    FOR UPDATE;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'المورد المحدد غير موجود';
    END IF;
  END IF;

  FOR v_item IN SELECT value FROM jsonb_array_elements(p_items)
  LOOP
    v_qty := (v_item->>'quantity')::integer;
    v_cost := (v_item->>'unit_cost')::numeric;
    IF v_qty <= 0 OR v_cost::text IN ('NaN','Infinity','-Infinity')
       OR v_cost < 0 THEN
      RAISE EXCEPTION 'الكمية أو تكلفة الشراء غير صحيحة';
    END IF;

    v_units := COALESCE(v_item->'imei_units','[]'::jsonb);
    IF jsonb_array_length(v_units) > 0
       AND jsonb_array_length(v_units) <> v_qty THEN
      RAISE EXCEPTION 'عدد أرقام IMEI يجب أن يساوي كمية الصنف';
    END IF;

    SELECT * INTO v_product
    FROM public.erp_products
    WHERE id=(v_item->>'product_id')::uuid AND owner_id=v_owner
    FOR UPDATE;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'أحد المنتجات غير موجود';
    END IF;

    SELECT count(*) INTO v_tracked
    FROM public.erp_product_units
    WHERE owner_id=v_owner AND product_id=v_product.id;
    IF v_tracked > 0 AND jsonb_array_length(v_units) <> v_qty THEN
      RAISE EXCEPTION 'هذا المنتج مسجل بتتبع IMEI؛ أدخل أرقام كل الأجهزة في فاتورة الشراء';
    END IF;

    v_subtotal := v_subtotal + (v_qty * v_cost);
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
      RAISE EXCEPTION 'طريقة الدفع غير صحيحة';
    END IF;
    IF v_amount > 0 THEN
      v_paid := v_paid + v_amount;
    END IF;
  END LOOP;

  IF v_paid > v_total THEN
    RAISE EXCEPTION 'إجمالي المدفوع أكبر من قيمة الفاتورة';
  END IF;
  IF v_paid < v_total AND p_supplier_id IS NULL THEN
    RAISE EXCEPTION 'اختر المورد لتسجيل المبلغ المتبقي كمديونية عليه';
  END IF;

  INSERT INTO public.erp_purchase_invoices
    (owner_id,invoice_no,invoice_date,supplier_id,supplier_name,
     subtotal,discount,total,paid,notes)
  VALUES
    (v_owner,trim(p_invoice_no),COALESCE(p_invoice_date,current_date),
     p_supplier_id,v_supplier_name,v_subtotal,COALESCE(p_discount,0),
     v_total,v_paid,nullif(trim(p_notes),''))
  RETURNING id INTO v_invoice;

  FOR v_item IN SELECT value FROM jsonb_array_elements(p_items)
  LOOP
    v_qty := (v_item->>'quantity')::integer;
    v_cost := (v_item->>'unit_cost')::numeric;

    SELECT * INTO v_product
    FROM public.erp_products
    WHERE id=(v_item->>'product_id')::uuid AND owner_id=v_owner
    FOR UPDATE;

    IF v_product.quantity + v_qty > 0 THEN
      v_new_cost := (
        (v_product.quantity * COALESCE(v_product.cost_price,0)) +
        (v_qty * v_cost)
      ) / (v_product.quantity + v_qty);
    ELSE
      v_new_cost := v_cost;
    END IF;

    UPDATE public.erp_products
    SET quantity=quantity+v_qty,cost_price=round(v_new_cost,2),updated_at=now()
    WHERE id=v_product.id AND owner_id=v_owner;

    INSERT INTO public.erp_purchase_invoice_items
      (owner_id,invoice_id,product_id,product_name,quantity,unit_cost,line_total)
    VALUES
      (v_owner,v_invoice,v_product.id,v_product.name,v_qty,v_cost,v_qty*v_cost)
    RETURNING id INTO v_invoice_item;

    v_units := COALESCE(v_item->'imei_units','[]'::jsonb);
    FOR v_unit IN SELECT value FROM jsonb_array_elements(v_units)
    LOOP
      v_imei1 := nullif(regexp_replace(COALESCE(v_unit->>'imei1',''),'[^0-9]','','g'),'');
      v_imei2 := nullif(regexp_replace(COALESCE(v_unit->>'imei2',''),'[^0-9]','','g'),'');
      IF v_imei1 IS NULL AND v_imei2 IS NULL THEN
        RAISE EXCEPTION 'كل جهاز متتبع يجب أن يحتوي على IMEI واحد على الأقل';
      END IF;
      IF (v_imei1 IS NOT NULL AND NOT public.erp_imei_luhn_valid(v_imei1))
         OR (v_imei2 IS NOT NULL AND NOT public.erp_imei_luhn_valid(v_imei2))
         OR v_imei1=v_imei2 THEN
        RAISE EXCEPTION 'رقم IMEI غير صحيح أو لا يجتاز فحص الرقم';
      END IF;

      v_unit_barcode := 'IMEI-'||COALESCE(v_imei1,v_imei2);
      INSERT INTO public.erp_product_units
        (owner_id,product_id,imei1,imei2,unit_barcode,purchase_price,status)
      VALUES
        (v_owner,v_product.id,v_imei1,v_imei2,v_unit_barcode,v_cost,'in_stock')
      RETURNING id INTO v_payment_id;

      INSERT INTO public.erp_purchase_invoice_item_units
        (owner_id,invoice_item_id,product_unit_id)
      VALUES
        (v_owner,v_invoice_item,v_payment_id);
    END LOOP;
  END LOOP;

  IF p_supplier_id IS NOT NULL THEN
    IF v_total > 0 THEN
      INSERT INTO public.erp_party_transactions
        (owner_id,party_id,transaction_date,direction,amount,description)
      VALUES
        (v_owner,p_supplier_id,COALESCE(p_invoice_date,current_date),
         'increase',v_total,'فاتورة شراء رقم '||trim(p_invoice_no));
    END IF;
    IF v_paid > 0 THEN
      INSERT INTO public.erp_party_transactions
        (owner_id,party_id,transaction_date,direction,amount,description)
      VALUES
        (v_owner,p_supplier_id,COALESCE(p_invoice_date,current_date),
         'decrease',v_paid,'سداد من فاتورة شراء رقم '||trim(p_invoice_no));
    END IF;
  END IF;

  FOR v_payment IN SELECT value FROM jsonb_array_elements(p_payments)
  LOOP
    v_account := v_payment->>'account_code';
    v_amount := (v_payment->>'amount')::numeric;
    IF v_amount > 0 THEN
      INSERT INTO public.erp_purchase_payments
        (owner_id,invoice_id,account_code,amount)
      VALUES
        (v_owner,v_invoice,v_account,v_amount)
      RETURNING id INTO v_payment_id;

      INSERT INTO public.erp_cash_movements
        (owner_id,movement_date,direction,amount,description,
         source_type,source_id,account_code)
      VALUES
        (v_owner,COALESCE(p_invoice_date,current_date),'out',v_amount,
         'سداد فاتورة مشتريات رقم '||trim(p_invoice_no),
         'purchase_payment',v_payment_id,v_account);
    END IF;
  END LOOP;

  RETURN v_invoice;
END;
$func$;

REVOKE ALL ON FUNCTION public.erp_create_purchase(text,date,uuid,numeric,text,jsonb,jsonb)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.erp_create_purchase(text,date,uuid,numeric,text,jsonb,jsonb)
  TO authenticated;
