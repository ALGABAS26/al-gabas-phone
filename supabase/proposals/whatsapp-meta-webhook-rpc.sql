-- Use one delivery slot per owner/invoice across legacy image and new PDF sends.
-- Apply only after reviewing in an isolated test database.
create or replace function public.erp_wa_claim_invoice_delivery(
  p_owner_id uuid,
  p_invoice_id uuid
)
returns table(delivery_id uuid, delivery_status text, claimed boolean)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id uuid;
  v_status text;
begin
  if p_owner_id is null or p_invoice_id is null then
    raise exception 'owner_id and invoice_id are required';
  end if;
  if not exists (
    select 1 from public.erp_sales_invoices i
    where i.id = p_invoice_id and i.owner_id = p_owner_id and i.status = 'completed'
  ) then
    raise exception 'invoice is not eligible';
  end if;

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(p_owner_id::text || ':' || p_invoice_id::text, 0)
  );

  select d.id, d.status into v_id, v_status
  from private.erp_whatsapp_invoice_deliveries d
  where d.owner_id = p_owner_id
    and d.invoice_id = p_invoice_id
    and d.delivery_type in ('sale_invoice_image', 'sale_invoice_document')
  order by (d.status <> 'failed') desc, d.updated_at desc
  limit 1
  for update;

  if v_id is not null then
    if v_status <> 'failed' then
      return query select v_id, v_status, false;
      return;
    end if;
    update private.erp_whatsapp_invoice_deliveries d
    set status = 'processing',
        provider_message_id = null,
        accepted_at = null,
        error_code = null,
        updated_at = pg_catalog.now()
    where d.id = v_id
    returning d.id, d.status into v_id, v_status;
    return query select v_id, v_status, true;
    return;
  end if;

  insert into private.erp_whatsapp_invoice_deliveries(owner_id, invoice_id, delivery_type, status)
  values (p_owner_id, p_invoice_id, 'sale_invoice_document', 'processing')
  returning id, status into v_id, v_status;

  return query select v_id, v_status, true;
end;
$$;
revoke all on function public.erp_wa_claim_invoice_delivery(uuid, uuid) from public, anon, authenticated;
grant execute on function public.erp_wa_claim_invoice_delivery(uuid, uuid) to service_role;

-- PROPOSAL ONLY. Apply to a disposable/test database first.
-- Enables verified Meta delivery webhooks to update the private invoice ledger.
-- No direct table access is granted to anon/authenticated.

create or replace function public.erp_wa_apply_invoice_webhook(
  p_provider_message_id text,
  p_status text,
  p_error_code text default null
)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_updated boolean := false;
begin
  if p_provider_message_id is null or length(p_provider_message_id) > 255 then
    raise exception 'invalid provider message id';
  end if;
  if p_status not in ('accepted', 'delivered', 'read', 'failed') then
    raise exception 'invalid delivery status';
  end if;

  update private.erp_whatsapp_invoice_deliveries d
  set status = p_status,
      error_code = case when p_status = 'failed' then left(p_error_code, 80) else null end,
      accepted_at = case when p_status in ('accepted', 'delivered', 'read') then coalesce(d.accepted_at, pg_catalog.now()) else d.accepted_at end,
      updated_at = pg_catalog.now()
  where d.provider_message_id = p_provider_message_id
    and (
      (d.status = 'processing' and p_status in ('accepted', 'delivered', 'read', 'failed'))
      or (d.status = 'accepted' and p_status in ('delivered', 'read', 'failed'))
      or (d.status = 'delivered' and p_status = 'read')
    );

  v_updated := found;

  update private.erp_whatsapp_maintenance_notifications m
  set status = p_status,
      error_code = case when p_status = 'failed' then left(p_error_code, 80) else null end,
      accepted_at = case when p_status in ('accepted', 'delivered', 'read') then coalesce(m.accepted_at, pg_catalog.now()) else m.accepted_at end,
      updated_at = pg_catalog.now()
  where m.provider_message_id = p_provider_message_id
    and (
      (m.status = 'processing' and p_status in ('accepted', 'delivered', 'read', 'failed'))
      or (m.status = 'accepted' and p_status in ('delivered', 'read', 'failed'))
      or (m.status = 'delivered' and p_status = 'read')
    );

  v_updated := v_updated or found;
  return v_updated;
end;
$$;

revoke all on function public.erp_wa_apply_invoice_webhook(text, text, text) from public, anon, authenticated;
grant execute on function public.erp_wa_apply_invoice_webhook(text, text, text) to service_role;
