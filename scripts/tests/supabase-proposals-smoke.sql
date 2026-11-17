\set ON_ERROR_STOP on

insert into auth.users(id) values ('11111111-1111-4111-8111-111111111111');
insert into public.erp_sales_invoices(id, owner_id, status)
values ('22222222-2222-4222-8222-222222222222', '11111111-1111-4111-8111-111111111111', 'completed');

-- Authenticated user creates one paid-deposit order and one zero-deposit order.
set role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-4111-8111-111111111111', false);
select public.erp_create_maintenance_order_with_deposit(
  'TEST-DEP-1','Test Customer','01000000000','Test Phone','Black','Screen repair',null,100,25,null,'drawer'
);
select public.erp_create_maintenance_order_with_deposit(
  'TEST-DEP-2','Test Customer','01000000000','Test Phone','Black','Diagnosis',null,100,0,null,'drawer'
);
reset role;

do $$
begin
  if (select count(*) from public.erp_maintenance_orders) <> 2 then
    raise exception 'maintenance order insert count mismatch';
  end if;
  if (select count(*) from public.erp_cash_movements) <> 1 then
    raise exception 'deposit should create exactly one cash movement';
  end if;
  if not exists (
    select 1 from public.erp_cash_movements
    where source_type = 'maintenance_deposit'
      and amount = 25
      and direction = 'in'
      and account_code = 'drawer'
  ) then
    raise exception 'deposit cash movement content mismatch';
  end if;
end;
$$;

-- A rejected deposit must not leave an order or cash movement behind.
do $$
declare
  before_orders integer;
  before_movements integer;
begin
  select count(*) into before_orders from public.erp_maintenance_orders;
  select count(*) into before_movements from public.erp_cash_movements;
  begin
    perform public.erp_create_maintenance_order_with_deposit(
      'TEST-DEP-BAD','Test Customer',null,'Test Phone',null,'Repair',null,100,101,null,'drawer'
    );
    raise exception 'expected deposit validation failure';
  exception when others then
    if sqlerrm = 'expected deposit validation failure' then raise; end if;
    if sqlerrm <> 'العربون يجب ألا يتجاوز التكلفة المتوقعة' then raise; end if;
  end;
  if (select count(*) from public.erp_maintenance_orders) <> before_orders then
    raise exception 'invalid deposit left an orphan maintenance order';
  end if;
  if (select count(*) from public.erp_cash_movements) <> before_movements then
    raise exception 'invalid deposit left an orphan cash movement';
  end if;
end;
$$;

-- Claiming is idempotent; failed claims can retry without retaining old provider IDs.
set role service_role;
select * from public.erp_wa_claim_invoice_delivery(
  '11111111-1111-4111-8111-111111111111','22222222-2222-4222-8222-222222222222'
);
select * from public.erp_wa_claim_invoice_delivery(
  '11111111-1111-4111-8111-111111111111','22222222-2222-4222-8222-222222222222'
);
reset role;

update private.erp_whatsapp_invoice_deliveries
set status='failed', provider_message_id='wamid-old', accepted_at=now()
where invoice_id='22222222-2222-4222-8222-222222222222';

set role service_role;
select * from public.erp_wa_claim_invoice_delivery(
  '11111111-1111-4111-8111-111111111111','22222222-2222-4222-8222-222222222222'
);
reset role;

do $$
begin
  if not exists (
    select 1 from private.erp_whatsapp_invoice_deliveries
    where invoice_id='22222222-2222-4222-8222-222222222222'
      and status='processing' and provider_message_id is null and accepted_at is null
  ) then
    raise exception 'failed invoice retry did not reset old provider state';
  end if;
end;
$$;

update private.erp_whatsapp_invoice_deliveries
set provider_message_id='wamid-invoice'
where invoice_id='22222222-2222-4222-8222-222222222222';

-- Create and claim a maintenance notification, then update both ledgers through the webhook RPC.
set role service_role;
select * from public.erp_wa_claim_maintenance_notification(
  '11111111-1111-4111-8111-111111111111',
  (select id from public.erp_maintenance_orders where ticket_no='TEST-DEP-1'),
  false
);
reset role;

update private.erp_whatsapp_maintenance_notifications
set provider_message_id='wamid-maint'
where maintenance_order_id=(select id from public.erp_maintenance_orders where ticket_no='TEST-DEP-1');

set role service_role;
select public.erp_wa_apply_invoice_webhook('wamid-invoice','delivered',null);
select public.erp_wa_apply_invoice_webhook('wamid-invoice','accepted',null);
select public.erp_wa_apply_invoice_webhook('wamid-invoice','read',null);
select public.erp_wa_apply_invoice_webhook('wamid-maint','delivered',null);
reset role;

do $$
begin
  if (select status from private.erp_whatsapp_invoice_deliveries where provider_message_id='wamid-invoice') <> 'read' then
    raise exception 'invoice webhook state did not advance monotonically to read';
  end if;
  if (select status from private.erp_whatsapp_maintenance_notifications where provider_message_id='wamid-maint') <> 'delivered' then
    raise exception 'maintenance webhook state did not advance to delivered';
  end if;
  if (select accepted_at from private.erp_whatsapp_invoice_deliveries where provider_message_id='wamid-invoice') is null then
    raise exception 'accepted_at timestamp was not populated';
  end if;
end;
$$;

select 'Supabase SQL proposal smoke tests passed.' as result;
