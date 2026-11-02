-- AL GABAS ERP — Upgrade 21 staging regression test
-- Run ONLY in a separate Supabase test project after applying upgrade-21.sql.
-- Replace UUID with an existing synthetic auth.users.id in that project.
-- All inserted maintenance orders are rolled back. Never run in production.

begin;
set local role authenticated;
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000001',true);

do $test$
declare
  v_owner uuid := auth.uid();
  v_ticket text;
  v_count integer;
  v_failed boolean;
begin
  if v_owner is null then raise exception 'Synthetic authenticated user is required'; end if;

  -- Case 1: valid repair order with optional fields.
  v_ticket := public.erp_create_maintenance_order(
    'RPC test customer','01000000000','iPhone test device','Black',
    'Screen replacement','Box and charger',350,'Staging test order'
  );
  select count(*) into v_count
  from public.erp_maintenance_orders
  where owner_id=v_owner and ticket_no=v_ticket
    and ticket_no like 'REP-' || to_char(current_date,'YYYYMMDD') || '-%'
    and customer_name='RPC test customer' and customer_phone='01000000000'
    and device_name='iPhone test device' and device_color='Black'
    and problem='Screen replacement' and accessories='Box and charger'
    and estimated_cost=350 and notes='Staging test order' and status='received';
  if v_count<>1 then raise exception 'FAIL: maintenance order fields, owner binding, or ticket format'; end if;

  -- Case 2: blank optional fields normalize to NULL and cost defaults to zero.
  v_ticket := public.erp_create_maintenance_order('RPC test customer 2',null,'Android test','   ','No power','   ');
  select count(*) into v_count
  from public.erp_maintenance_orders
  where owner_id=v_owner and ticket_no=v_ticket
    and customer_phone is null and device_color is null
    and accessories is null and estimated_cost=0 and notes is null;
  if v_count<>1 then raise exception 'FAIL: optional defaults or blank normalization'; end if;

  v_failed:=false;
  begin perform public.erp_create_maintenance_order('   ',null,'Device','Color','Problem');
  exception when others then v_failed:=true; end;
  if not v_failed then raise exception 'FAIL: blank customer name accepted'; end if;

  v_failed:=false;
  begin perform public.erp_create_maintenance_order('Customer',null,'   ',null,'Problem');
  exception when others then v_failed:=true; end;
  if not v_failed then raise exception 'FAIL: blank device name accepted'; end if;

  v_failed:=false;
  begin perform public.erp_create_maintenance_order('Customer',null,'Device',null,'   ');
  exception when others then v_failed:=true; end;
  if not v_failed then raise exception 'FAIL: blank problem accepted'; end if;

  v_failed:=false;
  begin perform public.erp_create_maintenance_order('Customer',null,'Device',null,'Problem',null,-1);
  exception when others then v_failed:=true; end;
  if not v_failed then raise exception 'FAIL: negative estimated cost accepted'; end if;

  v_failed:=false;
  begin perform public.erp_create_maintenance_order('Customer',null,'Device',null,'Problem',null,null);
  exception when others then v_failed:=true; end;
  if not v_failed then raise exception 'FAIL: NULL estimated cost accepted'; end if;

  perform set_config('request.jwt.claim.sub','',true);
  v_failed:=false;
  begin perform public.erp_create_maintenance_order('Customer',null,'Device',null,'Problem');
  exception when others then v_failed:=true; end;
  if not v_failed then raise exception 'FAIL: unauthenticated maintenance order accepted'; end if;

  raise notice 'PASS: maintenance order creation, server ticket, owner binding, validation, and authentication';
end;
$test$;
rollback;
