-- AL GABAS ERP — Upgrade 21: validated maintenance order creation RPC
-- Prepared for a separate Supabase staging project only.
-- DO NOT execute against the live Supabase project in this stage.
--
-- The database now generates the unique repair ticket number. Existing
-- maintenance status, cost fields, and update workflows are unchanged.

begin;

create or replace function public.erp_create_maintenance_order(
  p_customer_name text,
  p_customer_phone text default null,
  p_device_name text default null,
  p_device_color text default null,
  p_problem text default null,
  p_accessories text default null,
  p_estimated_cost numeric default 0,
  p_notes text default null
)
returns text
language plpgsql
security invoker
set search_path = pg_catalog, public
as $function$
declare
  v_owner uuid := auth.uid();
  v_ticket text;
  v_customer text := nullif(btrim(p_customer_name), '');
  v_phone text := nullif(btrim(p_customer_phone), '');
  v_device text := nullif(btrim(p_device_name), '');
  v_color text := nullif(btrim(p_device_color), '');
  v_problem text := nullif(btrim(p_problem), '');
  v_accessories text := nullif(btrim(p_accessories), '');
  v_notes text := nullif(btrim(p_notes), '');
begin
  if v_owner is null then
    raise exception 'يجب تسجيل الدخول';
  end if;

  if v_customer is null then
    raise exception 'اسم العميل مطلوب';
  end if;
  if v_device is null then
    raise exception 'اسم الجهاز مطلوب';
  end if;
  if v_problem is null then
    raise exception 'وصف العطل مطلوب';
  end if;

  if p_estimated_cost is null
     or p_estimated_cost < 0
     or p_estimated_cost::text in ('NaN','Infinity','-Infinity') then
    raise exception 'التكلفة التقديرية يجب أن تكون صفرًا أو رقمًا موجبًا وصحيحًا';
  end if;

  -- Generate the ticket server-side rather than trusting a browser timestamp.
  v_ticket := 'REP-' || to_char(current_date,'YYYYMMDD') || '-'
              || upper(substr(replace(gen_random_uuid()::text,'-',''),1,8));

  insert into public.erp_maintenance_orders (
    owner_id, ticket_no, customer_name, customer_phone, device_name,
    device_color, problem, accessories, estimated_cost, notes, status
  )
  values (
    v_owner, v_ticket, v_customer, v_phone, v_device,
    v_color, v_problem, v_accessories, p_estimated_cost, v_notes, 'received'
  );

  return v_ticket;
end;
$function$;

revoke all on function public.erp_create_maintenance_order(text,text,text,text,text,text,numeric,text)
  from public, anon;
grant execute on function public.erp_create_maintenance_order(text,text,text,text,text,text,numeric,text)
  to authenticated;

commit;
