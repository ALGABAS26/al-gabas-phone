-- AL GABAS ERP — Upgrade 26 staging regression test
-- Apply upgrade-26.sql only in a separate staging project after upgrades 01–25.
-- Replace synthetic auth UUID and fixture product/supplier IDs as needed.
-- All writes are rolled back. Never run this script in production.

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub',
  '00000000-0000-0000-0000-000000000001', true);

DO $test$
DECLARE
  v_owner uuid := auth.uid();
  v_id uuid;
  v_failed boolean;
  v_product uuid := '66666666-6666-6666-6666-666666666666';
  v_supplier uuid := NULL;
  v_before_qty integer;
  v_after_qty integer;
  v_before_movements integer;
  v_after_movements integer;
  v_before_invoices integer;
  v_after_invoices integer;
BEGIN
  IF v_owner IS NULL THEN
    RAISE EXCEPTION 'Test setup failed: synthetic auth user is not active';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.erp_products
    WHERE id=v_product AND owner_id=v_owner
  ) THEN
    RAISE EXCEPTION 'Replace v_product with an existing synthetic ERP product ID';
  END IF;

  -- Expense: SQL NULL values and non-finite amount must be rejected.
  v_failed := false;
  BEGIN
    PERFORM public.erp_record_expense(current_date,'اختبار',NULL,'drawer','اختبار');
  EXCEPTION WHEN OTHERS THEN v_failed := true;
  END;
  IF NOT v_failed THEN RAISE EXCEPTION 'FAIL: NULL expense amount accepted'; END IF;

  v_failed := false;
  BEGIN
    PERFORM public.erp_record_expense(current_date,'اختبار',1,NULL,'اختبار');
  EXCEPTION WHEN OTHERS THEN v_failed := true;
  END;
  IF NOT v_failed THEN RAISE EXCEPTION 'FAIL: NULL expense account accepted'; END IF;

  v_failed := false;
  BEGIN
    PERFORM public.erp_record_expense(current_date,'اختبار','NaN'::numeric,'drawer','اختبار');
  EXCEPTION WHEN OTHERS THEN v_failed := true;
  END;
  IF NOT v_failed THEN RAISE EXCEPTION 'FAIL: non-finite expense amount accepted'; END IF;

  -- Transfer: NULL account/date-independent fields and non-finite amount rejected.
  v_failed := false;
  BEGIN
    PERFORM public.erp_transfer_cash(current_date,NULL,'drawer',1,NULL);
  EXCEPTION WHEN OTHERS THEN v_failed := true;
  END;
  IF NOT v_failed THEN RAISE EXCEPTION 'FAIL: NULL transfer source accepted'; END IF;

  v_failed := false;
  BEGIN
    PERFORM public.erp_transfer_cash(current_date,'drawer','instapay',NULL,NULL);
  EXCEPTION WHEN OTHERS THEN v_failed := true;
  END;
  IF NOT v_failed THEN RAISE EXCEPTION 'FAIL: NULL transfer amount accepted'; END IF;

  v_failed := false;
  BEGIN
    PERFORM public.erp_transfer_cash(current_date,'drawer','instapay','Infinity'::numeric,NULL);
  EXCEPTION WHEN OTHERS THEN v_failed := true;
  END;
  IF NOT v_failed THEN RAISE EXCEPTION 'FAIL: non-finite transfer amount accepted'; END IF;

  -- Purchase: malformed top-level JSON must fail before invoice or inventory writes.
  SELECT quantity INTO v_before_qty
  FROM public.erp_products WHERE id=v_product AND owner_id=v_owner;
  SELECT count(*) INTO v_before_movements
  FROM public.erp_cash_movements WHERE owner_id=v_owner;
  SELECT count(*) INTO v_before_invoices
  FROM public.erp_purchase_invoices WHERE owner_id=v_owner;

  v_failed := false;
  BEGIN
    PERFORM public.erp_create_purchase(
      'RPC26-NULL-ITEMS-'||replace(gen_random_uuid()::text,'-',''),
      current_date,v_supplier,0,NULL,NULL,'[]'::jsonb
    );
  EXCEPTION WHEN OTHERS THEN v_failed := true;
  END;
  IF NOT v_failed THEN RAISE EXCEPTION 'FAIL: NULL purchase items accepted'; END IF;

  v_failed := false;
  BEGIN
    PERFORM public.erp_create_purchase(
      'RPC26-NULL-PAYMENTS-'||replace(gen_random_uuid()::text,'-',''),
      current_date,v_supplier,0,NULL,
      jsonb_build_array(jsonb_build_object(
        'product_id',v_product,'quantity',1,'unit_cost',1
      )),NULL
    );
  EXCEPTION WHEN OTHERS THEN v_failed := true;
  END;
  IF NOT v_failed THEN RAISE EXCEPTION 'FAIL: NULL purchase payments accepted'; END IF;

  v_failed := false;
  BEGIN
    PERFORM public.erp_create_purchase(
      'RPC26-NULL-ELEMENT-'||replace(gen_random_uuid()::text,'-',''),
      current_date,v_supplier,0,NULL,
      jsonb_build_array(NULL),'[]'::jsonb
    );
  EXCEPTION WHEN OTHERS THEN v_failed := true;
  END;
  IF NOT v_failed THEN RAISE EXCEPTION 'FAIL: NULL purchase item element accepted'; END IF;

  v_failed := false;
  BEGIN
    PERFORM public.erp_create_purchase(
      'RPC26-SCALAR-ELEMENT-'||replace(gen_random_uuid()::text,'-',''),
      current_date,v_supplier,0,NULL,
      jsonb_build_array('not-an-object'),'[]'::jsonb
    );
  EXCEPTION WHEN OTHERS THEN v_failed := true;
  END;
  IF NOT v_failed THEN RAISE EXCEPTION 'FAIL: scalar purchase item accepted'; END IF;

  v_failed := false;
  BEGIN
    PERFORM public.erp_create_purchase(
      'RPC26-BAD-UUID-'||replace(gen_random_uuid()::text,'-',''),
      current_date,v_supplier,0,NULL,
      jsonb_build_array(jsonb_build_object(
        'product_id','not-a-uuid','quantity',1,'unit_cost',1
      )), '[]'::jsonb
    );
  EXCEPTION WHEN OTHERS THEN v_failed := true;
  END;
  IF NOT v_failed THEN RAISE EXCEPTION 'FAIL: invalid product UUID accepted'; END IF;

  v_failed := false;
  BEGIN
    PERFORM public.erp_create_purchase(
      'RPC26-NAN-DISCOUNT-'||replace(gen_random_uuid()::text,'-',''),
      current_date,v_supplier,'NaN'::numeric,NULL,
      jsonb_build_array(jsonb_build_object(
        'product_id',v_product,'quantity',1,'unit_cost',1
      )), '[]'::jsonb
    );
  EXCEPTION WHEN OTHERS THEN v_failed := true;
  END;
  IF NOT v_failed THEN RAISE EXCEPTION 'FAIL: NaN purchase discount accepted'; END IF;

  SELECT quantity INTO v_after_qty
  FROM public.erp_products WHERE id=v_product AND owner_id=v_owner;
  SELECT count(*) INTO v_after_movements
  FROM public.erp_cash_movements WHERE owner_id=v_owner;
  SELECT count(*) INTO v_after_invoices
  FROM public.erp_purchase_invoices WHERE owner_id=v_owner;
  IF v_after_qty IS DISTINCT FROM v_before_qty
     OR v_after_movements IS DISTINCT FROM v_before_movements
     OR v_after_invoices IS DISTINCT FROM v_before_invoices THEN
    RAISE EXCEPTION 'FAIL: rejected purchase changed inventory, invoices, or cash movements';
  END IF;

  RAISE NOTICE 'PASS: expense/transfer NULL and non-finite guards; purchase JSON, UUID, and discount validation';
END;
$test$;

ROLLBACK;

-- Additional positive staging checks should use a synthetic supplier and product:
-- * purchase one non-IMEI item with a partial payment and verify invoice, stock,
--   weighted-average cost, supplier ledger, payment row, and cash movement.
-- * purchase an IMEI-tracked product with exact valid Luhn IMEI units and verify
--   purchase-line mapping; reject count mismatch, duplicate IMEI and malformed IMEI.
-- * transfer cash between two accounts and verify one paired out/in movement,
--   stable source UUID, unchanged combined balance, and insufficient-balance rejection.
-- * record an expense and verify exactly one expense plus one matching cash outflow.
-- Concurrency testing must use two independent staging sessions.
