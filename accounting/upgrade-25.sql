-- AL GABAS ERP — Upgrade 25: serialize Fawry close chronology per owner
-- Apply only in a separate staging project after upgrades 01–24.
-- This migration does not touch public.products, storefront policies, or storefront code.
-- It is intentionally not executed by this assistant.

CREATE OR REPLACE FUNCTION public.erp_save_fawry_daily_close(
  p_close_date date,
  p_opening_balance numeric,
  p_topup_amount numeric,
  p_closing_balance numeric,
  p_profit numeric,
  p_notes text DEFAULT NULL,
  p_funding_account text DEFAULT 'drawer'
) RETURNS uuid
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = pg_catalog, public
AS $func$
DECLARE
  v_owner uuid := auth.uid();
  v_id uuid;
  v_previous numeric(14,2);
  v_next_opening numeric(14,2);
BEGIN
  IF v_owner IS NULL THEN
    RAISE EXCEPTION 'يجب تسجيل الدخول';
  END IF;
  IF p_close_date IS NULL THEN
    RAISE EXCEPTION 'تاريخ التقفيل مطلوب';
  END IF;
  IF p_opening_balance IS NULL OR p_topup_amount IS NULL
     OR p_closing_balance IS NULL OR p_profit IS NULL THEN
    RAISE EXCEPTION 'كل أرصدة التقفيل وقيمه مطلوبة';
  END IF;
  IF p_opening_balance::text IN ('NaN','Infinity','-Infinity')
     OR p_topup_amount::text IN ('NaN','Infinity','-Infinity')
     OR p_closing_balance::text IN ('NaN','Infinity','-Infinity')
     OR p_profit::text IN ('NaN','Infinity','-Infinity')
     OR p_opening_balance < 0 OR p_topup_amount < 0
     OR p_closing_balance < 0 OR p_profit < 0 THEN
    RAISE EXCEPTION 'القيم لا يمكن أن تكون سالبة أو غير محدودة';
  END IF;
  IF p_funding_account IS NULL OR p_funding_account NOT IN
     ('drawer','vodafone_cash','instapay') THEN
    RAISE EXCEPTION 'مصدر الشحن غير صحيح';
  END IF;

  -- One transaction-level lock per owner serializes all date changes, so two
  -- adjacent-day closes cannot validate against stale predecessor/successor data.
  PERFORM pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(v_owner::text, 0)
  );

  PERFORM public.erp_init_cash_accounts();

  SELECT closing_balance
    INTO v_previous
  FROM public.erp_fawry_daily_closings
  WHERE owner_id = v_owner AND close_date < p_close_date
  ORDER BY close_date DESC
  LIMIT 1;

  IF v_previous IS NOT NULL
     AND p_opening_balance IS DISTINCT FROM v_previous THEN
    RAISE EXCEPTION 'رصيد افتتاح اليوم يجب أن يساوي رصيد إغلاق آخر تقفيل محفوظ: %',
      v_previous;
  END IF;

  -- Editing/inserting a historical close must also preserve the next day's
  -- opening balance; otherwise later closes would silently become inconsistent.
  SELECT opening_balance
    INTO v_next_opening
  FROM public.erp_fawry_daily_closings
  WHERE owner_id = v_owner AND close_date > p_close_date
  ORDER BY close_date ASC
  LIMIT 1;

  IF v_next_opening IS NOT NULL
     AND p_closing_balance IS DISTINCT FROM v_next_opening THEN
    RAISE EXCEPTION 'رصيد إغلاق اليوم يجب أن يساوي رصيد افتتاح أول تقفيل لاحق: %',
      v_next_opening;
  END IF;

  INSERT INTO public.erp_fawry_daily_closings
    (owner_id,close_date,opening_balance,topup_amount,closing_balance,
     profit,notes,funding_account)
  VALUES
    (v_owner,p_close_date,p_opening_balance,p_topup_amount,p_closing_balance,
     p_profit,nullif(trim(p_notes),''),p_funding_account)
  ON CONFLICT(owner_id,close_date) DO UPDATE SET
    opening_balance = excluded.opening_balance,
    topup_amount = excluded.topup_amount,
    closing_balance = excluded.closing_balance,
    profit = excluded.profit,
    notes = excluded.notes,
    funding_account = excluded.funding_account,
    updated_at = now()
  RETURNING id INTO v_id;

  -- Keep the stable close UUID as the cash movement source identity.
  IF p_topup_amount > 0 THEN
    INSERT INTO public.erp_cash_movements
      (owner_id,movement_date,direction,amount,description,
       source_type,source_id,account_code)
    VALUES
      (v_owner,p_close_date,'out',p_topup_amount,
       'شحن ماكينة فوري من '||
       CASE p_funding_account
         WHEN 'drawer' THEN 'درج الكاش'
         WHEN 'vodafone_cash' THEN 'فودافون كاش'
         ELSE 'إنستا باي'
       END,
       'fawry_topup',v_id,p_funding_account)
    ON CONFLICT(owner_id,source_type,source_id) DO UPDATE SET
      movement_date = excluded.movement_date,
      direction = 'out',
      amount = excluded.amount,
      description = excluded.description,
      account_code = excluded.account_code;
  ELSE
    DELETE FROM public.erp_cash_movements
    WHERE owner_id = v_owner
      AND source_type = 'fawry_topup'
      AND source_id = v_id;
  END IF;

  RETURN v_id;
END;
$func$;

REVOKE ALL ON FUNCTION public.erp_save_fawry_daily_close(date,numeric,numeric,numeric,numeric,text,text)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.erp_save_fawry_daily_close(date,numeric,numeric,numeric,numeric,text,text)
  TO authenticated;
