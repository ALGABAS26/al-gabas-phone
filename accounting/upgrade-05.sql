-- AL GABAS PHONE ERP - Upgrade 05: customers, suppliers and party ledger
-- Run after upgrade-04.sql. Adds isolated ERP tables only.
create table if not exists public.erp_parties (
 id uuid primary key default gen_random_uuid(),
 owner_id uuid not null references auth.users(id) on delete cascade,
 party_type text not null check (party_type in ('customer','supplier')),
 name text not null,
 phone text,
 address text,
 opening_balance numeric(14,2) not null default 0 check(opening_balance>=0),
 notes text,
 created_at timestamptz not null default now(),
 updated_at timestamptz not null default now()
);
create index if not exists erp_parties_owner_type_name_idx on public.erp_parties(owner_id,party_type,name);
create table if not exists public.erp_party_transactions (
 id uuid primary key default gen_random_uuid(),
 owner_id uuid not null references auth.users(id) on delete cascade,
 party_id uuid not null references public.erp_parties(id) on delete cascade,
 transaction_date date not null default current_date,
 direction text not null check(direction in ('increase','decrease')),
 amount numeric(14,2) not null check(amount>0),
 description text not null,
 created_at timestamptz not null default now()
);
create index if not exists erp_party_tx_party_date_idx on public.erp_party_transactions(owner_id,party_id,transaction_date desc,created_at desc);
alter table public.erp_parties enable row level security;
alter table public.erp_party_transactions enable row level security;
drop policy if exists erp_parties_owner_all on public.erp_parties;
create policy erp_parties_owner_all on public.erp_parties for all to authenticated using(owner_id=auth.uid()) with check(owner_id=auth.uid());
drop policy if exists erp_party_tx_owner_all on public.erp_party_transactions;
create policy erp_party_tx_owner_all on public.erp_party_transactions for all to authenticated using(owner_id=auth.uid()) with check(owner_id=auth.uid());
grant select,insert,update,delete on public.erp_parties,public.erp_party_transactions to authenticated;
