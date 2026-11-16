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
  p_maintenance_order_id uuid
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

  return query select v_id, v_id is not null;
end;
$$;
revoke all on function public.erp_wa_claim_maintenance_notification(uuid, uuid) from public, anon, authenticated;
grant execute on function public.erp_wa_claim_maintenance_notification(uuid, uuid) to service_role;

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
