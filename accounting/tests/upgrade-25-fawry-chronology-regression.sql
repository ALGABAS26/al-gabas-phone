-- AL GABAS ERP — Upgrade 25 staging regression test
-- Apply upgrade-25.sql in a SEPARATE Supabase test project first.
-- Uses only synthetic authenticated-user rows and rolls back all writes.
-- Never run in production.

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub',
  '00000000-0000-0000-0000-000000000001', true);

DO $test$
DECLARE
  v_owner uuid := auth.uid();
  v_base_date date;
  v_prev_id uuid;
  v_target_id uuid;
  v_next_id uuid;
  v_failed boolean;
  v_saved_closing numeric(14,2);
BEGIN
  IF v_owner IS NULL THEN
    RAISE EXCEPTION 'Test setup failed: synthetic auth user is not active';
  END IF;

  SELECT COALESCE(max(close_date),current_date) + 10
    INTO v_base_date
  FROM public.erp_fawry_daily_closings
  WHERE owner_id = v_owner;

  v_prev_id := public.erp_save_fawry_daily_close(
    v_base_date,100,0,100,0,'Upgrade 25 predecessor','drawer'
  );
  v_target_id := public.erp_save_fawry_daily_close(
    v_base_date+1,100,0,100,0,'Upgrade 25 target','drawer'
  );
  v_next_id := public.erp_save_fawry_daily_close(
    v_base_date+2,100,0,100,0,'Upgrade 25 successor','drawer'
  );

  -- A historical edit that breaks the next day's opening balance must fail.
  v_failed := false;
  BEGIN
    PERFORM public.erp_save_fawry_daily_close(
      v_base_date+1,100,0,90,0,'Must preserve successor','drawer'
    );
  EXCEPTION WHEN OTHERS THEN
    v_failed := true;
  END;
  IF NOT v_failed THEN
    RAISE EXCEPTION 'FAIL: historical close edit broke the next close opening balance';
  END IF;

  SELECT closing_balance INTO v_saved_closing
  FROM public.erp_fawry_daily_closings
  WHERE id=v_target_id AND owner_id=v_owner;
  IF v_saved_closing IS DISTINCT FROM 100 THEN
    RAISE EXCEPTION 'FAIL: rejected historical edit changed the saved close';
  END IF;

  -- SQL NULL and invalid enum inputs must fail before writes.
  v_failed := false;
  BEGIN
    PERFORM public.erp_save_fawry_daily_close(
      NULL,100,0,100,0,NULL,'drawer'
    );
  EXCEPTION WHEN OTHERS THEN
    v_failed := true;
  END;
  IF NOT v_failed THEN
    RAISE EXCEPTION 'FAIL: SQL NULL close date was accepted';
  END IF;

  v_failed := false;
  BEGIN
    PERFORM public.erp_save_fawry_daily_close(
      v_base_date+3,NULL,0,100,0,NULL,'drawer'
    );
  EXCEPTION WHEN OTHERS THEN
    v_failed := true;
  END;
  IF NOT v_failed THEN
    RAISE EXCEPTION 'FAIL: SQL NULL opening balance was accepted';
  END IF;

  v_failed := false;
  BEGIN
    PERFORM public.erp_save_fawry_daily_close(
      v_base_date+3,100,0,100,0,NULL,NULL
    );
  EXCEPTION WHEN OTHERS THEN
    v_failed := true;
  END;
  IF NOT v_failed THEN
    RAISE EXCEPTION 'FAIL: SQL NULL funding account was accepted';
  END IF;

  RAISE NOTICE 'PASS: Fawry predecessor/successor chronology and NULL validation';
END;
$test$;

ROLLBACK;

-- Two-session staging concurrency check:
-- Session A and B use the same synthetic owner and adjacent dates. Start A's
-- close RPC and keep its transaction open. Start B's next-day close RPC using
-- an opening balance based on A's proposed closing balance. B must wait on the
-- owner advisory transaction lock, then validate against A's committed row.
-- Repeat with B starting first, and with an edit to an older close while a later
-- close is being saved. Verify no broken predecessor/successor chain and that
-- each close retains one stable fawry_topup cash movement source_id.
-- This concurrency check is not simulated by the single-session script above.
