# AG system — WhatsApp image and Windows integration gates

Status: WhatsApp implementation remains a prototype on the work branch. It is not merged or deployed, and automatic sending remains disabled.

## Verified production baseline
- The Android/web app continues to use the existing Supabase project configured in `config.js`.
- Sales invoices are created by `public.erp_create_sale`; invoice and item tables retain their existing RLS and owner-scoped access.
- The existing invoice print flow remains available.
- The existing Android build packages the `accounting` web app through the Capacitor wrapper.

## WhatsApp sale invoice image prototype
- The client renders a PNG from the signed-in user's completed invoice, its items, and shop settings.
- The Edge Function independently verifies the caller's JWT, invoice ownership, completed status, stored customer phone, and presence of invoice items.
- The recipient is read from `erp_sales_invoices.customer_phone`; the client cannot choose a different destination.
- The function uploads the PNG to WhatsApp Cloud API and sends it using an approved template with an IMAGE header.
- The private delivery ledger has a unique owner/invoice/type key. A server-only claim RPC prevents concurrent/duplicate sends. Definite provider rejections can be retried; uncertain outcomes are not automatically retried.
- `WA_AUTO_SEND_ENABLED=false` remains in client config. Server sending is separately blocked unless `WA_SEND_ENABLED=true`.

## Already completed on the existing Supabase project
- Created `private.erp_whatsapp_invoice_deliveries`; it is currently empty.
- Enabled RLS and revoked direct table access from `anon` and `authenticated`.
- Added server-only RPCs `public.erp_wa_claim_invoice_delivery` and `public.erp_wa_update_invoice_delivery`; execute is granted to `service_role` only.
- Verified that authenticated users cannot read/insert into the private ledger or execute the claim RPC, while the server role can.
- These changes did not replace or migrate the existing sales invoice tables or business data.

## Remaining WhatsApp gates
1. Obtain/confirm the required WhatsApp Cloud API server credentials and an approved template with an IMAGE header. Do not put credentials in GitHub, client config, or chat.
2. Add the required values as Supabase Edge Function secrets, including `SUPABASE_SERVICE_ROLE_KEY`; keep `WA_SEND_ENABLED=false`.
3. Review and deploy the Edge Function only after the secrets are present and deployment is explicitly approved.
4. Run non-delivery checks first: authentication, ownership, invoice status, missing phone, invalid Egyptian mobile number, missing items, and duplicate claim. Keep live sending disabled during these checks.
5. Use a designated Meta test sender and test recipient for an explicitly approved end-to-end message test.
6. Verify accepted, definite rejection, timeout/unknown, duplicate, and safe retry behavior. A timeout after the send request must remain `unknown` and must not be resent automatically.
7. Add webhook processing for delivered/read/failed provider status updates; until then, `accepted` means the provider accepted the request, not proof of delivery.
8. Enable automatic sending only after all acceptance tests pass and the owner explicitly approves it.

## Safety boundaries
- Never store Meta tokens or Supabase service-role/secret keys in GitHub, `config.js`, Android assets, or chat.
- Do not alter existing production invoice tables, policies, users, or shop data as part of this prototype without separate approval.
- No Edge Function has been deployed and no real WhatsApp message has been sent.
- Do not merge the work branch or enable automatic sending without explicit approval.

## Windows desktop — not started
- Keep Supabase as the single source of truth shared with Android.
- A Tauri desktop shell is a future implementation task; it is not present in this branch yet.
- Reuse the existing Supabase Auth and RLS model; store session material using OS-protected storage.
- Do not introduce a second business database or replication layer.
- Before release, validate printing, Arabic text, barcode/camera fallback, offline/reconnect, session expiry, installer upgrade/uninstall, and cross-platform data consistency.
- Do not publish a signed installer until signing credentials and explicit release approval exist.
