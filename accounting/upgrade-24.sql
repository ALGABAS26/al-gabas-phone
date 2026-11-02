-- AL GABAS ERP — Upgrade 24: serialize return quantities on original invoice lines
-- Apply only in a separate staging project after upgrades 01–23.
-- This migration does not touch public.products, storefront policies, or storefront code.
-- It is intentionally not executed by this assistant.

CREATE OR REPLACE FUNCTION public.erp_post_return(
  p_return_no text,
  p_return_type text,
  p_invoice_id uuid,
  p_return_date date,
  p_notes text,
  p_items jsonb,
  p_refund_payments jsonb
) RETURNS uuid
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = pg_catalog, public
AS $func$
DECLARE
  v_owner uuid := auth.uid();
  v_return uuid;
  v_party uuid;
  v_party_name text := '';
  v_item jsonb;
  v_orig record;
  v_qty integer;
  v_price numeric(14,2);
  v_cost numeric(14,2);
  v_total numeric(14,2) := 0;
  v_refunded numeric(14,2) := 0;
  v_pay jsonb;
  v_account text;
  v_amount numeric(14,2);
  v_lock_id uuid;
BEGIN
  IF v_owner IS NULL THEN
    RAISE EXCEPTION 'يجب تسجيل الدخول';
  END IF;
  IF p_return_type IS NULL OR p_return_type NOT IN ('sale','purchase') THEN
    RAISE EXCEPTION 'نوع المرتجع غير صحيح';
  END IF;
  IF p_invoice_id IS NULL THEN
    RAISE EXCEPTION 'الفاتورة الأصلية مطلوبة';
  END IF;
  IF COALESCE(trim(p_return_no), '') = '' THEN
    RAISE EXCEPTION 'رقم المرتجع مطلوب';
  END IF;
  IF p_items IS NULL OR jsonb_typeof(p_items) IS DISTINCT FROM 'array'
     OR jsonb_array_length(p_items) = 0 THEN
    RAISE EXCEPTION 'أضف صنفًا واحدًا على الأقل';
  END IF;

  -- Reject malformed items before UUID/integer casts or any writes.
  IF EXISTS (
    SELECT 1
    FROM jsonb_array_elements(p_items) AS a(value)
    WHERE jsonb_typeof(a.value) IS DISTINCT FROM 'object'
       OR COALESCE(a.value->>'invoice_item_id','') !~
          '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
       OR COALESCE(a.value->>'quantity','') !~ '^[1-9][0-9]*$'
  ) THEN
    RAISE EXCEPTION 'بيانات أصناف المرتجع غير مكتملة أو غير صحيحة';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM jsonb_array_elements(p_items) WITH ORDINALITY a(value,n),
         jsonb_array_elements(p_items) WITH ORDINALITY b(value,n)
    WHERE a.n < b.n
      AND a.value->>'invoice_item_id' = b.value->>'invoice_item_id'
  ) THEN
    RAISE EXCEPTION 'لا تكرر نفس سطر الفاتورة في المرتجع';
  END IF;

  IF p_return_type = 'sale' THEN
    SELECT customer_name
      INTO v_party_name
    FROM public.erp_sales_invoices
    WHERE id = p_invoice_id AND owner_id = v_owner AND status = 'completed'
    FOR UPDATE;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'فاتورة البيع غير موجودة أو ملغاة';
    END IF;
  ELSE
    SELECT supplier_id, supplier_name
      INTO v_party, v_party_name
    FROM public.erp_purchase_invoices
    WHERE id = p_invoice_id AND owner_id = v_owner
    FOR UPDATE;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'فاتورة الشراء غير موجودة';
    END IF;
  END IF;

  -- Lock all referenced original lines in a stable UUID order. The invoice
  -- header lock above serializes this RPC per invoice; line locks make the
  -- quantity invariant explicit and protect future code paths that also lock
  -- invoice lines. Missing/foreign lines are rejected in the validation loop.
  IF p_return_type = 'sale' THEN
    FOR v_lock_id IN
      SELECT s.id
      FROM public.erp_sales_invoice_items AS s
      JOIN (
        SELECT DISTINCT (a.value->>'invoice_item_id')::uuid AS id
        FROM jsonb_array_elements(p_items) AS a(value)
      ) AS requested ON requested.id = s.id
      WHERE s.invoice_id = p_invoice_id AND s.owner_id = v_owner
      ORDER BY s.id
    LOOP
      PERFORM 1
      FROM public.erp_sales_invoice_items
      WHERE id = v_lock_id AND invoice_id = p_invoice_id AND owner_id = v_owner
      FOR UPDATE;
    END LOOP;
  ELSE
    FOR v_lock_id IN
      SELECT p.id
      FROM public.erp_purchase_invoice_items AS p
      JOIN (
        SELECT DISTINCT (a.value->>'invoice_item_id')::uuid AS id
        FROM jsonb_array_elements(p_items) AS a(value)
      ) AS requested ON requested.id = p.id
      WHERE p.invoice_id = p_invoice_id AND p.owner_id = v_owner
      ORDER BY p.id
    LOOP
      PERFORM 1
      FROM public.erp_purchase_invoice_items
      WHERE id = v_lock_id AND invoice_id = p_invoice_id AND owner_id = v_owner
      FOR UPDATE;
    END LOOP;
  END IF;

  FOR v_item IN SELECT value FROM jsonb_array_elements(p_items)
  LOOP
    v_qty := (v_item->>'quantity')::integer;
    IF p_return_type = 'sale' THEN
      SELECT product_id, product_name, quantity, unit_price, unit_cost
        INTO v_orig
      FROM public.erp_sales_invoice_items
      WHERE id = (v_item->>'invoice_item_id')::uuid
        AND invoice_id = p_invoice_id AND owner_id = v_owner;
    ELSE
      SELECT product_id, product_name, quantity,
             unit_cost AS unit_price, unit_cost
        INTO v_orig
      FROM public.erp_purchase_invoice_items
      WHERE id = (v_item->>'invoice_item_id')::uuid
        AND invoice_id = p_invoice_id AND owner_id = v_owner;
    END IF;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'صنف غير تابع للفاتورة المحددة';
    END IF;

    IF v_qty > (
      v_orig.quantity - COALESCE((
        SELECT sum(ri.quantity)
        FROM public.erp_return_items AS ri
        JOIN public.erp_returns AS rr ON rr.id = ri.return_id
        WHERE rr.invoice_id = p_invoice_id
          AND rr.return_type = p_return_type
          AND rr.owner_id = v_owner
          AND ri.invoice_item_id = (v_item->>'invoice_item_id')::uuid
      ), 0)
    ) THEN
      RAISE EXCEPTION 'كمية المرتجع أكبر من الكمية المتبقية للمرتجع';
    END IF;

    v_price := v_orig.unit_price;
    v_cost := COALESCE(v_orig.unit_cost, 0);
    v_total := v_total + (v_qty * v_price);
  END LOOP;

  IF p_return_type = 'sale' THEN
    IF p_refund_payments IS NULL
       OR jsonb_typeof(p_refund_payments) IS DISTINCT FROM 'array' THEN
      RAISE EXCEPTION 'بيانات رد المبلغ غير صحيحة';
    END IF;

    IF EXISTS (
      SELECT 1
      FROM jsonb_array_elements(p_refund_payments) AS a(value)
      WHERE jsonb_typeof(a.value) IS DISTINCT FROM 'object'
         OR COALESCE(a.value->>'account_code','') NOT IN
            ('drawer','vodafone_cash','instapay')
         OR COALESCE(a.value->>'amount','') !~ '^[0-9]+([.][0-9]+)?$'
    ) THEN
      RAISE EXCEPTION 'بيانات رد المبلغ غير مكتملة أو غير صحيحة';
    END IF;

    FOR v_pay IN SELECT value FROM jsonb_array_elements(p_refund_payments)
    LOOP
      v_account := v_pay->>'account_code';
      v_amount := (v_pay->>'amount')::numeric;
      IF v_amount::text IN ('NaN','Infinity','-Infinity') OR v_amount < 0 THEN
        RAISE EXCEPTION 'مصدر رد المبلغ غير صحيح';
      END IF;
      v_refunded := v_refunded + v_amount;
    END LOOP;

    IF v_refunded > v_total THEN
      RAISE EXCEPTION 'المبلغ المرتجع أكبر من قيمة الأصناف';
    END IF;
  ELSE
    -- Preserve the existing purchase-return behavior: no cash refund rows.
    v_refunded := 0;
  END IF;

  INSERT INTO public.erp_returns
    (owner_id,return_no,return_type,return_date,invoice_id,party_id,
     party_name,total,refunded,notes)
  VALUES
    (v_owner,trim(p_return_no),p_return_type,COALESCE(p_return_date,current_date),
     p_invoice_id,v_party,COALESCE(v_party_name,''),v_total,v_refunded,
     nullif(trim(p_notes),''))
  RETURNING id INTO v_return;

  FOR v_item IN SELECT value FROM jsonb_array_elements(p_items)
  LOOP
    v_qty := (v_item->>'quantity')::integer;

    IF p_return_type = 'sale' THEN
      SELECT * INTO v_orig
      FROM public.erp_sales_invoice_items
      WHERE id = (v_item->>'invoice_item_id')::uuid
        AND invoice_id = p_invoice_id AND owner_id = v_owner;

      UPDATE public.erp_products
      SET quantity = quantity + v_qty, updated_at = now()
      WHERE id = v_orig.product_id AND owner_id = v_owner;
    ELSE
      SELECT id, product_id, product_name, quantity,
             unit_cost AS unit_price, unit_cost
        INTO v_orig
      FROM public.erp_purchase_invoice_items
      WHERE id = (v_item->>'invoice_item_id')::uuid
        AND invoice_id = p_invoice_id AND owner_id = v_owner;

      UPDATE public.erp_products
      SET quantity = quantity - v_qty, updated_at = now()
      WHERE id = v_orig.product_id AND owner_id = v_owner
        AND quantity >= v_qty;
      IF NOT FOUND THEN
        RAISE EXCEPTION 'المخزون الحالي لا يكفي لمرتجع الشراء';
      END IF;
    END IF;

    v_cost := COALESCE(v_orig.unit_cost, 0);
    INSERT INTO public.erp_return_items
      (owner_id,return_id,invoice_item_id,product_id,product_name,
       quantity,unit_price,unit_cost,line_total)
    VALUES
      (v_owner,v_return,(v_item->>'invoice_item_id')::uuid,
       v_orig.product_id,v_orig.product_name,v_qty,v_orig.unit_price,
       v_cost,v_qty*v_orig.unit_price);
  END LOOP;

  IF p_return_type = 'sale' THEN
    FOR v_pay IN SELECT value FROM jsonb_array_elements(p_refund_payments)
    LOOP
      v_account := v_pay->>'account_code';
      v_amount := (v_pay->>'amount')::numeric;
      IF v_amount > 0 THEN
        INSERT INTO public.erp_cash_movements
          (owner_id,movement_date,direction,amount,description,
           source_type,source_id,account_code)
        VALUES
          (v_owner,COALESCE(p_return_date,current_date),'out',v_amount,
           'رد مبلغ مرتجع بيع رقم '||trim(p_return_no),
           'sale_return',gen_random_uuid(),v_account);
      END IF;
    END LOOP;
  ELSE
    IF v_party IS NOT NULL AND v_total > 0 THEN
      INSERT INTO public.erp_party_transactions
        (owner_id,party_id,transaction_date,direction,amount,description)
      VALUES
        (v_owner,v_party,COALESCE(p_return_date,current_date),'decrease',
         v_total,'مرتجع مشتريات رقم '||trim(p_return_no));
    END IF;
  END IF;

  RETURN v_return;
END;
$func$;

REVOKE ALL ON FUNCTION public.erp_post_return(text,text,uuid,date,text,jsonb,jsonb)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.erp_post_return(text,text,uuid,date,text,jsonb,jsonb)
  TO authenticated;
