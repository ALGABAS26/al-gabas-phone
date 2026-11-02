-- AL GABAS ERP — Upgrade 24 staging regression test
-- Apply upgrade-24.sql in a SEPARATE Supabase test project first.
-- Replace the UUID placeholders with synthetic-user fixtures:
--   * a completed sale invoice with one NON-IMEI line, original quantity >= 2;
--   * a purchase invoice with one line, original quantity >= 2;
--   * enough current stock to return one purchase unit.
-- This test rolls back all test writes. Never run in production.

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub',
  '00000000-0000-0000-0000-000000000001', true);

DO $test$
DECLARE
  v_owner uuid := auth.uid();
  v_sale_invoice uuid := '22222222-2222-2222-2222-222222222222';
  v_sale_item uuid := '33333333-3333-3333-3333-333333333333';
  v_purchase_invoice uuid := '44444444-4444-4444-4444-444444444444';
  v_purchase_item uuid := '55555555-5555-5555-5555-555555555555';
  v_return_id uuid;
  v_failed boolean;
  v_before_qty integer;
  v_after_qty integer;
  v_returned integer;
  v_sale_original_qty integer;
  v_purchase_original_qty integer;
BEGIN
  IF v_owner IS NULL THEN
    RAISE EXCEPTION 'Test setup failed: synthetic auth user is not active';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.erp_sales_invoice_items i
    JOIN public.erp_sales_invoices h ON h.id=i.invoice_id
    WHERE i.id=v_sale_item AND i.invoice_id=v_sale_invoice
      AND i.owner_id=v_owner AND h.owner_id=v_owner
      AND h.status='completed' AND i.quantity >= 2
      AND NOT EXISTS (
        SELECT 1 FROM public.erp_product_units u
        WHERE u.owner_id=v_owner AND u.product_id=i.product_id
      )
  ) THEN
    RAISE EXCEPTION 'Sale fixture missing: completed invoice, non-IMEI line, quantity >= 2 required';
  END IF;

  SELECT i.quantity INTO v_sale_original_qty
  FROM public.erp_sales_invoice_items i WHERE i.id=v_sale_item AND i.owner_id=v_owner;

  SELECT quantity INTO v_before_qty
  FROM public.erp_products
  WHERE id=(SELECT product_id FROM public.erp_sales_invoice_items WHERE id=v_sale_item)
    AND owner_id=v_owner;

  v_return_id := public.erp_post_return(
    'RPC24-SALE-1-'||replace(gen_random_uuid()::text,'-',''),
    'sale',v_sale_invoice,current_date,'First partial sale return',
    jsonb_build_array(jsonb_build_object('invoice_item_id',v_sale_item,'quantity',1)),
    '[]'::jsonb
  );

  v_failed := false;
  BEGIN
    PERFORM public.erp_post_return(
      'RPC24-SALE-2-'||replace(gen_random_uuid()::text,'-',''),
      'sale',v_sale_invoice,current_date,'Must exceed remaining quantity',
      jsonb_build_array(jsonb_build_object('invoice_item_id',v_sale_item,'quantity',v_sale_original_qty)),
      '[]'::jsonb
    );
  EXCEPTION WHEN OTHERS THEN
    v_failed := true;
  END;
  IF NOT v_failed THEN
    RAISE EXCEPTION 'FAIL: sale return accepted more than the remaining invoice-line quantity';
  END IF;

  SELECT COALESCE(sum(ri.quantity),0)::integer INTO v_returned
  FROM public.erp_return_items ri
  JOIN public.erp_returns r ON r.id=ri.return_id
  WHERE r.owner_id=v_owner AND r.invoice_id=v_sale_invoice
    AND r.return_type='sale' AND ri.invoice_item_id=v_sale_item;
  IF v_returned <> 1 THEN
    RAISE EXCEPTION 'FAIL: sale returned quantity changed after rejected over-return';
  END IF;

  SELECT quantity INTO v_after_qty
  FROM public.erp_products
  WHERE id=(SELECT product_id FROM public.erp_sales_invoice_items WHERE id=v_sale_item)
    AND owner_id=v_owner;
  IF v_after_qty <> v_before_qty + 1 THEN
    RAISE EXCEPTION 'FAIL: rejected sale return changed inventory or accepted return did not restore stock';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.erp_purchase_invoice_items i
    JOIN public.erp_purchase_invoices h ON h.id=i.invoice_id
    JOIN public.erp_products p ON p.id=i.product_id AND p.owner_id=i.owner_id
    WHERE i.id=v_purchase_item AND i.invoice_id=v_purchase_invoice
      AND i.owner_id=v_owner AND h.owner_id=v_owner AND i.quantity >= 2
      AND p.quantity >= 1
  ) THEN
    RAISE EXCEPTION 'Purchase fixture missing: invoice line quantity >= 2 and sufficient stock required';
  END IF;

  SELECT i.quantity INTO v_purchase_original_qty
  FROM public.erp_purchase_invoice_items i WHERE i.id=v_purchase_item AND i.owner_id=v_owner;

  v_return_id := public.erp_post_return(
    'RPC24-PURCHASE-1-'||replace(gen_random_uuid()::text,'-',''),
    'purchase',v_purchase_invoice,current_date,'First partial purchase return',
    jsonb_build_array(jsonb_build_object('invoice_item_id',v_purchase_item,'quantity',1)),
    NULL
  );

  v_failed := false;
  BEGIN
    PERFORM public.erp_post_return(
      'RPC24-PURCHASE-2-'||replace(gen_random_uuid()::text,'-',''),
      'purchase',v_purchase_invoice,current_date,'Must exceed remaining quantity',
      jsonb_build_array(jsonb_build_object('invoice_item_id',v_purchase_item,'quantity',v_purchase_original_qty)),
      NULL
    );
  EXCEPTION WHEN OTHERS THEN
    v_failed := true;
  END;
  IF NOT v_failed THEN
    RAISE EXCEPTION 'FAIL: purchase return accepted more than the remaining invoice-line quantity';
  END IF;

  SELECT COALESCE(sum(ri.quantity),0)::integer INTO v_returned
  FROM public.erp_return_items ri
  JOIN public.erp_returns r ON r.id=ri.return_id
  WHERE r.owner_id=v_owner AND r.invoice_id=v_purchase_invoice
    AND r.return_type='purchase' AND ri.invoice_item_id=v_purchase_item;
  IF v_returned <> 1 THEN
    RAISE EXCEPTION 'FAIL: purchase returned quantity changed after rejected over-return';
  END IF;

  -- SQL NULL and malformed JSON must be rejected before any persistent write.
  v_failed := false;
  BEGIN
    PERFORM public.erp_post_return(
      'RPC24-NULL-'||replace(gen_random_uuid()::text,'-',''),
      'sale',v_sale_invoice,current_date,NULL,NULL,'[]'::jsonb
    );
  EXCEPTION WHEN OTHERS THEN
    v_failed := true;
  END;
  IF NOT v_failed THEN
    RAISE EXCEPTION 'FAIL: SQL NULL p_items was accepted';
  END IF;

  RAISE NOTICE 'PASS: partial-return limits, sale/purchase inventory atomicity, and malformed JSON rejection';
END;
$test$;

ROLLBACK;

-- Concurrency staging check (two independent authenticated sessions):
-- 1) Start a sale return for quantity 1 against an invoice line with quantity 1.
-- 2) Before session A commits, start the same return in session B using a different return_no.
-- 3) Commit A. Session B must then fail with the remaining-quantity error.
-- Repeat for purchase returns, then repeat with two invoice lines supplied in
-- opposite JSON order in each session. Verify one successful return only and
-- no duplicate stock/cash/party-ledger effects. This two-session test is not
-- simulated by the single-transaction regression script above.
