-- PROPOSAL ONLY. Review and apply to a disposable/test database first.
-- Do not execute against production as part of this change.
alter table public.erp_maintenance_orders
  add column if not exists deposit numeric(14,2) not null default 0
  check (deposit >= 0);

create table if not exists private.erp_whatsapp_maintenance_notifications (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references auth.users(id) on delete cascade,
  maintenance_order_id uuid not null references public.erp_maintenance_orders(id) on delete cascade,
  status text not null default 'processing'
    check (status in ('processing','accepted','delivered','read','failed','unknown')),
  provider_message_id text,
  error_code text,
  accepted_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint erp_wa_maintenance_once unique(owner_id, maintenance_order_id)
);
alter table private.erp_whatsapp_maintenance_notifications enable row level security;
revoke all on table private.erp_whatsapp_maintenance_notifications from public, anon, authenticated;
grant usage on schema private to service_role;
grant all on table private.erp_whatsapp_maintenance_notifications to service_role;

-- The private ledger is accessed only through narrowly scoped service-role RPCs.
create or replace function public.erp_wa_claim_maintenance_notification(
  p_owner_id uuid,
  p_maintenance_order_id uuid,
  p_retry_failed boolean default false
)
returns table(notification_id uuid, claimed boolean)
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_id uuid;
begin
  insert into private.erp_whatsapp_maintenance_notifications(owner_id, maintenance_order_id, status)
  values (p_owner_id, p_maintenance_order_id, 'processing')
  on conflict (owner_id, maintenance_order_id) do nothing
  returning id into v_id;

  if v_id is null and p_retry_failed then
    update private.erp_whatsapp_maintenance_notifications
    set status = 'processing',
        provider_message_id = null,
        error_code = null,
        accepted_at = null,
        updated_at = pg_catalog.now()
    where owner_id = p_owner_id
      and maintenance_order_id = p_maintenance_order_id
      and status = 'failed'
    returning id into v_id;
  end if;

  return query select v_id, v_id is not null;
end;
$$;
revoke all on function public.erp_wa_claim_maintenance_notification(uuid, uuid, boolean) from public, anon, authenticated;
grant execute on function public.erp_wa_claim_maintenance_notification(uuid, uuid, boolean) to service_role;

create or replace function public.erp_wa_update_maintenance_notification(
  p_notification_id uuid,
  p_owner_id uuid,
  p_status text,
  p_provider_message_id text,
  p_error_code text,
  p_accepted_at timestamptz
)
returns boolean
language plpgsql
security invoker
set search_path = ''
as $$
begin
  update private.erp_whatsapp_maintenance_notifications
  set status = p_status,
      provider_message_id = p_provider_message_id,
      error_code = p_error_code,
      accepted_at = p_accepted_at,
      updated_at = pg_catalog.now()
  where id = p_notification_id
    and owner_id = p_owner_id;

  return found;
end;
$$;
revoke all on function public.erp_wa_update_maintenance_notification(uuid, uuid, text, text, text, timestamptz) from public, anon, authenticated;
grant execute on function public.erp_wa_update_maintenance_notification(uuid, uuid, text, text, text, timestamptz) to service_role;

-- Create the repair ticket and post its deposit as one atomic cash movement.
-- SECURITY INVOKER preserves the caller's RLS policies; no service-role bypass.
create or replace function public.erp_create_maintenance_order_with_deposit(
  p_ticket_no text,
  p_customer_name text,
  p_customer_phone text,
  p_device_name text,
  p_device_color text,
  p_problem text,
  p_accessories text,
  p_estimated_cost numeric,
  p_deposit numeric,
  p_notes text,
  p_payment_account text
)
returns uuid
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_owner uuid := auth.uid();
  v_order_id uuid;
begin
  if v_owner is null then
    raise exception 'يجب تسجيل الدخول';
  end if;
  if p_ticket_no is null or length(trim(p_ticket_no)) = 0
     or p_customer_name is null or length(trim(p_customer_name)) = 0
     or p_device_name is null or length(trim(p_device_name)) = 0
     or p_problem is null or length(trim(p_problem)) = 0 then
    raise exception 'بيانات أمر الصيانة الأساسية مطلوبة';
  end if;
  if p_estimated_cost is null or p_estimated_cost < 0
     or p_deposit is null or p_deposit < 0 or p_deposit > p_estimated_cost then
    raise exception 'العربون يجب ألا يتجاوز التكلفة المتوقعة';
  end if;
  if p_payment_account not in ('drawer', 'vodafone_cash', 'instapay') then
    raise exception 'حساب استلام العربون غير صالح';
  end if;

  perform public.erp_init_cash_accounts();

  insert into public.erp_maintenance_orders (
    owner_id, ticket_no, customer_name, customer_phone, device_name,
    device_color, problem, accessories, estimated_cost, deposit, notes
  ) values (
    v_owner, trim(p_ticket_no), trim(p_customer_name), nullif(trim(p_customer_phone), ''),
    trim(p_device_name), nullif(trim(p_device_color), ''), trim(p_problem),
    nullif(trim(p_accessories), ''), p_estimated_cost, p_deposit, nullif(trim(p_notes), '')
  )
  returning id into v_order_id;

  if p_deposit > 0 then
    insert into public.erp_cash_movements (
      owner_id, movement_date, direction, amount, description,
      source_type, source_id, account_code
    ) values (
      v_owner, current_date, 'in', p_deposit,
      'عربون أمر صيانة ' || trim(p_ticket_no),
      'maintenance_deposit', v_order_id, p_payment_account
    );
  end if;

  return v_order_id;
end;
$$;

revoke all on function public.erp_create_maintenance_order_with_deposit(text,text,text,text,text,text,text,numeric,numeric,text,text) from public, anon;
grant execute on function public.erp_create_maintenance_order_with_deposit(text,text,text,text,text,text,text,numeric,numeric,text,text) to authenticated;
