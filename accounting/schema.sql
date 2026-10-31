-- AL GABAS PHONE ERP - Initial isolated schema
-- Run in Supabase SQL Editor. Does not modify storefront products.
create extension if not exists pgcrypto;
create table if not exists public.erp_products (
 id uuid primary key default gen_random_uuid(),
 owner_id uuid not null references auth.users(id) on delete cascade,
 name text not null,
 category text not null default 'أخرى',
 condition text not null default 'new' check(condition in ('new','used','accessory')),
 cost_price numeric(14,2) not null default 0 check(cost_price>=0),
 sale_price numeric(14,2) not null default 0 check(sale_price>=0),
 quantity integer not null default 0 check(quantity>=0),
 barcode text not null,
 created_at timestamptz not null default now(),
 updated_at timestamptz not null default now(),
 unique(owner_id,barcode)
);
create table if not exists public.erp_product_units (
 id uuid primary key default gen_random_uuid(),
 owner_id uuid not null references auth.users(id) on delete cascade,
 product_id uuid not null references public.erp_products(id) on delete cascade,
 imei1 varchar(15),
 imei2 varchar(15),
 unit_barcode text not null,
 purchase_price numeric(14,2) not null default 0 check(purchase_price>=0),
 status text not null default 'in_stock' check(status in ('in_stock','sold','repair','returned','written_off')),
 created_at timestamptz not null default now(),
 unique(owner_id,unit_barcode),
 check(imei1 is null or imei1 ~ '^[0-9]{15}$'),
 check(imei2 is null or imei2 ~ '^[0-9]{15}$'),
 check(imei1 is null or imei2 is null or imei1<>imei2)
);
create unique index if not exists erp_units_imei1_unique on public.erp_product_units(owner_id,imei1) where imei1 is not null;
create unique index if not exists erp_units_imei2_unique on public.erp_product_units(owner_id,imei2) where imei2 is not null;
-- Prevent an IMEI entered in either slot from duplicating the other slot.
create or replace function public.erp_check_imei_unique() returns trigger language plpgsql as $$
begin
 if new.imei1 is not null and exists(select 1 from public.erp_product_units u where u.owner_id=new.owner_id and u.id<>coalesce(new.id,'00000000-0000-0000-0000-000000000000'::uuid) and (u.imei1=new.imei1 or u.imei2=new.imei1)) then raise exception 'IMEI already exists'; end if;
 if new.imei2 is not null and exists(select 1 from public.erp_product_units u where u.owner_id=new.owner_id and u.id<>coalesce(new.id,'00000000-0000-0000-0000-000000000000'::uuid) and (u.imei1=new.imei2 or u.imei2=new.imei2)) then raise exception 'IMEI already exists'; end if;
 return new;
end $$;
drop trigger if exists erp_units_imei_guard on public.erp_product_units;
create trigger erp_units_imei_guard before insert or update of imei1,imei2,owner_id on public.erp_product_units for each row execute function public.erp_check_imei_unique();

create table if not exists public.erp_fawry_transactions (
 id uuid primary key default gen_random_uuid(),
 owner_id uuid not null references auth.users(id) on delete cascade,
 type text not null check(type in ('topup','service','withdrawal','settlement','fee','reversal')),
 amount numeric(14,2) not null check(amount>0),
 commission numeric(14,2) not null default 0 check(commission>=0),
 fee numeric(14,2) not null default 0 check(fee>=0),
 reference text,
 status text not null default 'completed' check(status in ('completed','pending','failed')),
 notes text,
 created_at timestamptz not null default now()
);
create index if not exists erp_fawry_owner_date_idx on public.erp_fawry_transactions(owner_id,created_at desc);

alter table public.erp_products enable row level security;
alter table public.erp_product_units enable row level security;
alter table public.erp_fawry_transactions enable row level security;
drop policy if exists erp_products_owner_all on public.erp_products;
create policy erp_products_owner_all on public.erp_products for all to authenticated using(owner_id=auth.uid()) with check(owner_id=auth.uid());
drop policy if exists erp_units_owner_all on public.erp_product_units;
create policy erp_units_owner_all on public.erp_product_units for all to authenticated using(owner_id=auth.uid()) with check(owner_id=auth.uid());
drop policy if exists erp_fawry_owner_all on public.erp_fawry_transactions;
create policy erp_fawry_owner_all on public.erp_fawry_transactions for all to authenticated using(owner_id=auth.uid()) with check(owner_id=auth.uid());
grant select,insert,update,delete on public.erp_products to authenticated;
grant select,insert,update,delete on public.erp_product_units to authenticated;
grant select,insert,update,delete on public.erp_fawry_transactions to authenticated;
-- Disable public sign-ups in Supabase Auth settings; create only the owner's account.
-- Sales, purchases, customer/supplier balances, full accounting journals and atomic posting RPCs
-- are deliberately a later phase; do not use this foundation as a finished accounting system.