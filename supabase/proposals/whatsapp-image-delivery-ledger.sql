-- PROPOSAL ONLY — do not run against the live project without explicit owner approval.
-- Before enabling PostgREST access, verify this table is included in the project's exposed Data API schemas.
-- Create the WhatsApp delivery ledger after review, using a proper Supabase migration.
create table if not exists public.erp_whatsapp_invoice_deliveries (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references auth.users(id) on delete cascade,
  invoice_id uuid not null references public.erp_sales_invoices(id) on delete cascade,
  delivery_type text not null default 'sale_invoice_image'
    check (delivery_type = 'sale_invoice_image'),
  status text not null default 'processing'
    check (status in ('processing','accepted','delivered','read','failed','unknown')),
  provider_message_id text,
  error_code text,
  accepted_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (owner_id, invoice_id, delivery_type)
);

create index if not exists erp_wa_deliveries_owner_created_idx
  on public.erp_whatsapp_invoice_deliveries(owner_id, created_at desc);

alter table public.erp_whatsapp_invoice_deliveries enable row level security;

create policy erp_wa_deliveries_owner_select
  on public.erp_whatsapp_invoice_deliveries
  for select to authenticated
  using (owner_id = (select auth.uid()));

create policy erp_wa_deliveries_owner_insert
  on public.erp_whatsapp_invoice_deliveries
  for insert to authenticated
  with check (owner_id = (select auth.uid()));

create policy erp_wa_deliveries_owner_update
  on public.erp_whatsapp_invoice_deliveries
  for update to authenticated
  using (owner_id = (select auth.uid()))
  with check (owner_id = (select auth.uid()));

grant select, insert, update on public.erp_whatsapp_invoice_deliveries to authenticated;
