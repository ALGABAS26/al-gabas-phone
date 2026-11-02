-- AL GABAS STORE ERP - Upgrade 13: additive multi-shop foundation
-- IMPORTANT:
-- 1) Run only after upgrades 08-12 have been reviewed/applied in their documented order.
-- 2) This migration DOES NOT replace existing RLS policies or business RPCs.
-- 3) Existing owner_id-based access remains in force. Do not invite other shops yet.
-- 4) Does not modify public.products (storefront).

begin;

create table if not exists public.erp_shops (
  id uuid primary key default gen_random_uuid(),
  name text not null default 'محل جديد',
  slug text not null unique,
  phone text,
  address text,
  currency text not null default 'EGP',
  timezone text not null default 'Africa/Cairo',
  status text not null default 'active'
    check (status in ('active','suspended','closed')),
  created_by uuid not null references auth.users(id) on delete restrict,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.erp_shop_memberships (
  id uuid primary key default gen_random_uuid(),
  shop_id uuid not null references public.erp_shops(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  role text not null default 'viewer'
    check (role in ('owner','admin','accountant','sales','inventory','technician','viewer')),
  status text not null default 'active'
    check (status in ('active','invited','suspended')),
  created_at timestamptz not null default now(),
  unique (shop_id,user_id)
);
create index if not exists erp_shop_memberships_user_idx
  on public.erp_shop_memberships(user_id,status);

create table if not exists public.erp_shop_subscriptions (
  id uuid primary key default gen_random_uuid(),
  shop_id uuid not null unique references public.erp_shops(id) on delete cascade,
  plan_code text not null default 'trial',
  status text not null default 'trial'
    check (status in ('trial','active','past_due','suspended','cancelled','expired')),
  starts_at timestamptz not null default now(),
  expires_at timestamptz,
  grace_until timestamptz,
  provider_reference text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.erp_shop_audit_log (
  id bigint generated always as identity primary key,
  shop_id uuid not null references public.erp_shops(id) on delete cascade,
  actor_user_id uuid references auth.users(id) on delete set null,
  action text not null,
  entity_table text,
  entity_id text,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);
create index if not exists erp_shop_audit_log_shop_date_idx
  on public.erp_shop_audit_log(shop_id,created_at desc);

-- Keep these new management tables private until membership-based policies
-- and shop onboarding are implemented in a later, separately reviewed upgrade.
alter table public.erp_shops enable row level security;
alter table public.erp_shop_memberships enable row level security;
alter table public.erp_shop_subscriptions enable row level security;
alter table public.erp_shop_audit_log enable row level security;

-- Add nullable shop_id to every ERP business table. Existing owner_id RLS stays
-- unchanged, so this foundation does not widen access or alter current workflows.
do $migration$
declare
  t text;
  tables text[] := array[
    'erp_products','erp_product_units','erp_fawry_transactions',
    'erp_sales_invoices','erp_sales_invoice_items','erp_sales_payments',
    'erp_sales_invoice_item_units',
    'erp_purchase_invoices','erp_purchase_invoice_items','erp_purchase_payments',
    'erp_purchase_invoice_item_units',
    'erp_parties','erp_party_transactions',
    'erp_cash_accounts','erp_cash_movements','erp_cash_transfers',
    'erp_fawry_daily_closings','erp_maintenance_orders','erp_shop_settings',
    'erp_expenses','erp_stock_counts','erp_stock_count_items',
    'erp_returns','erp_return_items'
  ];
begin
  foreach t in array tables loop
    if to_regclass('public.' || t) is not null
       and exists (
         select 1 from information_schema.columns
         where table_schema='public' and table_name=t and column_name='owner_id'
       ) then
      execute format('alter table public.%I add column if not exists shop_id uuid references public.erp_shops(id)',t);
    end if;
  end loop;
end
$migration$;

-- Create one initial shop for every owner currently represented in ERP data.
-- This deliberately uses existing owner_id values, not auth.uid(), because SQL
-- Editor sessions do not necessarily have an authenticated end-user context.
do $seed$
declare
  t text;
  uid uuid;
  sid uuid;
  shop_tables text[] := array[
    'erp_products','erp_product_units','erp_fawry_transactions',
    'erp_sales_invoices','erp_sales_invoice_items','erp_sales_payments',
    'erp_sales_invoice_item_units',
    'erp_purchase_invoices','erp_purchase_invoice_items','erp_purchase_payments',
    'erp_purchase_invoice_item_units',
    'erp_parties','erp_party_transactions',
    'erp_cash_accounts','erp_cash_movements','erp_cash_transfers',
    'erp_fawry_daily_closings','erp_maintenance_orders','erp_shop_settings',
    'erp_expenses','erp_stock_counts','erp_stock_count_items',
    'erp_returns','erp_return_items'
  ];
begin
  foreach t in array shop_tables loop
    if to_regclass('public.' || t) is not null
       and exists (
         select 1 from information_schema.columns
         where table_schema='public' and table_name=t and column_name='owner_id'
       ) then
      for uid in execute format('select distinct owner_id from public.%I where owner_id is not null',t)
      loop
        select m.shop_id into sid
        from public.erp_shop_memberships m
        where m.user_id=uid and m.role='owner'
        order by m.created_at
        limit 1;

        if sid is null then
          insert into public.erp_shops(name,slug,created_by)
          values ('الجباس ستور','algabas-' || replace(gen_random_uuid()::text,'-',''),uid)
          returning id into sid;

          insert into public.erp_shop_memberships(shop_id,user_id,role,status)
          values (sid,uid,'owner','active');

          insert into public.erp_shop_subscriptions(shop_id,plan_code,status)
          values (sid,'founder','active');
        end if;

        execute format(
          'update public.%I set shop_id=$1 where owner_id=$2 and shop_id is null',
          t
        ) using sid,uid;
        sid := null;
      end loop;
    end if;
  end loop;
end
$seed$;

-- Reportable verification: no existing owner-owned ERP row should remain unassigned.
do $verify$
declare
  t text;
  n bigint;
  tables text[] := array[
    'erp_products','erp_product_units','erp_fawry_transactions',
    'erp_sales_invoices','erp_sales_invoice_items','erp_sales_payments',
    'erp_sales_invoice_item_units',
    'erp_purchase_invoices','erp_purchase_invoice_items','erp_purchase_payments',
    'erp_purchase_invoice_item_units',
    'erp_parties','erp_party_transactions',
    'erp_cash_accounts','erp_cash_movements','erp_cash_transfers',
    'erp_fawry_daily_closings','erp_maintenance_orders','erp_shop_settings',
    'erp_expenses','erp_stock_counts','erp_stock_count_items',
    'erp_returns','erp_return_items'
  ];
begin
  foreach t in array tables loop
    if to_regclass('public.' || t) is not null
       and exists (
         select 1 from information_schema.columns
         where table_schema='public' and table_name=t and column_name='owner_id'
       ) then
      execute format('select count(*) from public.%I where owner_id is not null and shop_id is null',t) into n;
      if n > 0 then
        raise exception 'Upgrade 13 stopped: table % has % rows without shop_id',t,n;
      end if;
    end if;
  end loop;
end
$verify$;

commit;

-- Post-run checks:
-- select count(*) as shops from public.erp_shops;
-- select count(*) as memberships from public.erp_shop_memberships;
-- select table_name,count(*) filter (where shop_id is null) as unassigned
-- from information_schema.columns c
-- where c.table_schema='public' and c.column_name='shop_id'
-- group by table_name order by table_name;
