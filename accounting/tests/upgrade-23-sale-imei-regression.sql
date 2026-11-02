-- AL GABAS ERP — Upgrade 23 staging regression test
-- Apply upgrade-23.sql in a SEPARATE Supabase test project first.
-- Preconditions: create a synthetic authenticated user and a test product for it
-- with quantity >= 1, one older unit already status='sold' with no sale mapping,
-- and at least one unit status='in_stock'. Replace the two UUID placeholders.
-- This test is transactional and rolls back all test writes. Never run in production.

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub',
  '00000000-0000-0000-0000-000000000001', true);

DO $test$
DECLARE
  v_owner uuid := auth.uid();
  v_product_id uuid := '11111111-1111-1111-1111-111111111111';
  v_legacy_sold_id uuid;
  v_selected_id uuid;
  v_invoice_id uuid;
  v_line_id uuid;
  v_link_count integer;
  v_failed boolean;
  v_invoice_no text := 'RPC23-' || replace(gen_random_uuid()::text,'-','');
BEGIN
  IF v_owner IS NULL THEN
    RAISE EXCEPTION 'Test setup failed: synthetic auth user is not active';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.erp_products
    WHERE id=v_product_id AND owner_id=v_owner AND quantity >= 1
  ) THEN
    RAISE EXCEPTION 'Test fixture missing: product must belong to test user and have quantity >= 1';
  END IF;

  SELECT id INTO v_legacy_sold_id
  FROM public.erp_product_units
  WHERE owner_id=v_owner AND product_id=v_product_id AND status='sold'
    AND NOT EXISTS (
      SELECT 1 FROM public.erp_sales_invoice_item_units m
      WHERE m.owner_id=v_owner AND m.product_unit_id=erp_product_units.id
    )
  ORDER BY created_at,id
  LIMIT 1;

  SELECT id INTO v_selected_id
  FROM public.erp_product_units
  WHERE owner_id=v_owner AND product_id=v_product_id AND status='in_stock'
  ORDER BY created_at,id
  LIMIT 1
  FOR UPDATE;

  IF v_legacy_sold_id IS NULL OR v_selected_id IS NULL THEN
    RAISE EXCEPTION 'Test fixture requires one sold/unlinked legacy unit and one in_stock unit';
  END IF;

  -- The sale must link the exact in_stock unit it changes to sold, not the
  -- older sold/unlinked legacy unit.
  v_invoice_id := public.erp_create_sale(
    v_invoice_no, current_date, 'Upgrade 23 test', null,
    0, 'Exact IMEI correlation regression',
    jsonb_build_array(jsonb_build_object(
      'product_id',v_product_id,
      'quantity',1,
      'unit_price',1
    )),
    '[]'::jsonb
  );

  SELECT id INTO v_line_id
  FROM public.erp_sales_invoice_items
  WHERE owner_id=v_owner AND invoice_id=v_invoice_id;

  SELECT count(*) INTO v_link_count
  FROM public.erp_sales_invoice_item_units
  WHERE owner_id=v_owner AND invoice_item_id=v_line_id
    AND product_unit_id=v_selected_id;

  IF v_link_count <> 1 THEN
    RAISE EXCEPTION 'FAIL: exact newly selected unit was not linked to the sale line';
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.erp_sales_invoice_item_units
    WHERE owner_id=v_owner AND invoice_item_id=v_line_id
      AND product_unit_id=v_legacy_sold_id
  ) THEN
    RAISE EXCEPTION 'FAIL: unrelated legacy sold/unlinked unit was incorrectly linked';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.erp_product_units
    WHERE id=v_legacy_sold_id AND owner_id=v_owner AND status='sold'
  ) THEN
    RAISE EXCEPTION 'FAIL: legacy unit state changed unexpectedly';
  END IF;

  -- SQL NULL and malformed array elements must fail before any invoice write.
  v_failed := false;
  BEGIN
    PERFORM public.erp_create_sale(
      'RPC23-NULL-'||replace(gen_random_uuid()::text,'-',''),
      current_date,'Test',null,0,null,NULL,'[]'::jsonb
    );
  EXCEPTION WHEN OTHERS THEN
    v_failed := true;
  END;
  IF NOT v_failed THEN
    RAISE EXCEPTION 'FAIL: SQL NULL p_items was accepted';
  END IF;

  v_failed := false;
  BEGIN
    PERFORM public.erp_create_sale(
      'RPC23-SCALAR-'||replace(gen_random_uuid()::text,'-',''),
      current_date,'Test',null,0,null,'[null]'::jsonb,'[]'::jsonb
    );
  EXCEPTION WHEN OTHERS THEN
    v_failed := true;
  END;
  IF NOT v_failed THEN
    RAISE EXCEPTION 'FAIL: scalar/null item element was accepted';
  END IF;

  v_failed := false;
  BEGIN
    PERFORM public.erp_create_sale(
      'RPC23-PAY-'||replace(gen_random_uuid()::text,'-',''),
      current_date,'Test',null,0,null,'[]'::jsonb,'[null]'::jsonb
    );
  EXCEPTION WHEN OTHERS THEN
    v_failed := true;
  END;
  IF NOT v_failed THEN
    RAISE EXCEPTION 'FAIL: scalar/null payment element was accepted';
  END IF;

  RAISE NOTICE 'PASS: exact IMEI correlation and malformed JSON rejection';
END;
$test$;

ROLLBACK;
