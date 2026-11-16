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
