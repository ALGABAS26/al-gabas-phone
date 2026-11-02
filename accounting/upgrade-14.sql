-- AL GABAS STORE ERP - Upgrade 14: secure current-shop profile read
-- Adds read-only access to the signed-in user's own shop metadata.
-- Does not change existing ERP business-table policies or write RPCs.
-- Does not enable onboarding of other shops.

begin;

create or replace function public.erp_my_shop_profile()
returns table (
 shop_id uuid,
 shop_name text,
 shop_slug text,
 shop_status text,
 member_role text,
 subscription_status text,
 subscription_expires_at timestamptz
)
language sql
stable
security definer
set search_path = public, pg_temp
as $$
 select s.id,s.name,s.slug,s.status,m.role,sub.status,sub.expires_at
 from public.erp_shop_memberships m
 join public.erp_shops s on s.id=m.shop_id
 left join public.erp_shop_subscriptions sub on sub.shop_id=s.id
 where m.user_id=auth.uid()
   and m.status='active'
 order by case when m.role='owner' then 0 else 1 end,s.created_at
 limit 1;
$$;

revoke all on function public.erp_my_shop_profile() from public,anon;
grant execute on function public.erp_my_shop_profile() to authenticated;

drop policy if exists erp_shops_read_own_memberships on public.erp_shops;
create policy erp_shops_read_own_memberships on public.erp_shops
 for select to authenticated
 using (
  exists (
   select 1 from public.erp_shop_memberships m
   where m.shop_id=erp_shops.id
     and m.user_id=auth.uid()
     and m.status='active'
  )
 );

drop policy if exists erp_memberships_read_own on public.erp_shop_memberships;
create policy erp_memberships_read_own on public.erp_shop_memberships
 for select to authenticated
 using (user_id=auth.uid());

drop policy if exists erp_subscriptions_read_own_shop on public.erp_shop_subscriptions;
create policy erp_subscriptions_read_own_shop on public.erp_shop_subscriptions
 for select to authenticated
 using (
  exists (
   select 1 from public.erp_shop_memberships m
   where m.shop_id=erp_shop_subscriptions.shop_id
     and m.user_id=auth.uid()
     and m.status='active'
     and m.role in ('owner','admin')
  )
 );

drop policy if exists erp_audit_read_own_shop on public.erp_shop_audit_log;
create policy erp_audit_read_own_shop on public.erp_shop_audit_log
 for select to authenticated
 using (
  exists (
   select 1 from public.erp_shop_memberships m
   where m.shop_id=erp_shop_audit_log.shop_id
     and m.user_id=auth.uid()
     and m.status='active'
     and m.role in ('owner','admin')
  )
 );

commit;

-- Verify as the signed-in owner in the app:
-- select * from public.erp_my_shop_profile();
-- Expected: exactly one row for the current owner shop.
