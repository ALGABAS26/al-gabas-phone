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
      accepted_at = case when p_status = 'accepted' then coalesce(d.accepted_at, pg_catalog.now()) else d.accepted_at end,
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
      accepted_at = case when p_status = 'accepted' then coalesce(m.accepted_at, pg_catalog.now()) else m.accepted_at end,
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
