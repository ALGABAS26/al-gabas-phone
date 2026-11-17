-- Synthetic minimal Supabase-like schema for proposal smoke tests only.
create role anon nologin;
create role authenticated nologin;
create role service_role nologin;

create schema auth;
create schema private;
create table auth.users (id uuid primary key);

create or replace function auth.uid()
returns uuid
language sql
stable
as $$
  select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid
$$;
grant usage on schema auth to authenticated, service_role;
grant execute on function auth.uid() to authenticated, service_role;

create table public.erp_sales_invoices (
  id uuid primary key,
  owner_id uuid not null references auth.users(id),
  status text not null
);

create table public.erp_maintenance_orders (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references auth.users(id),
  ticket_no text not null unique,
  customer_name text not null,
  customer_phone text,
  device_name text not null,
  device_color text,
  problem text not null,
  accessories text,
  estimated_cost numeric(14,2) not null,
  notes text
);

create table public.erp_cash_movements (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references auth.users(id),
  movement_date date not null,
  direction text not null check (direction in ('in','out')),
  amount numeric(14,2) not null check (amount > 0),
  description text not null,
  source_type text not null,
  source_id uuid not null,
  account_code text not null check (account_code in ('drawer','vodafone_cash','instapay')),
  unique(owner_id, source_type, source_id)
);

create table private.erp_whatsapp_invoice_deliveries (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references auth.users(id),
  invoice_id uuid not null references public.erp_sales_invoices(id),
  delivery_type text not null,
  status text not null check (status in ('processing','accepted','delivered','read','failed','unknown')),
  provider_message_id text,
  error_code text,
  accepted_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(owner_id, invoice_id, delivery_type)
);

create or replace function public.erp_init_cash_accounts()
returns void
language plpgsql
as $$ begin return; end; $$;

grant usage on schema public to authenticated, service_role;
grant insert, select on public.erp_maintenance_orders, public.erp_cash_movements to authenticated;
grant execute on function public.erp_init_cash_accounts() to authenticated;
grant usage on schema private to service_role;
grant all on private.erp_whatsapp_invoice_deliveries to service_role;
