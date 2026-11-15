# WhatsApp sale invoice image — prototype

This is an opt-in, disabled-by-default implementation scaffold.

## Behavior
- The Android/web client renders the signed-in user's completed sale invoice as a PNG image using the invoice rows loaded under existing RLS.
- The Edge Function independently verifies the user's JWT, invoice ownership, completed status, stored customer phone, and presence of invoice items.
- The function uploads the PNG to WhatsApp Cloud API and sends it using an approved image-header template.
- A unique owner/invoice delivery ledger prevents duplicate sends. A provider timeout is marked `unknown` and is never retried automatically.

## Required server secrets
- `WA_SEND_ENABLED=false` until acceptance testing is complete.
- `WA_ACCESS_TOKEN`
- `WA_PHONE_NUMBER_ID`
- `WA_IMAGE_TEMPLATE_NAME` (an approved WhatsApp template with an IMAGE header)
- `WA_TEMPLATE_LANGUAGE` (for example `ar`)
- `WA_GRAPH_API_VERSION` (defaults to `v25.0`)

The function uses the caller's JWT and the Supabase publishable key to verify the signed-in user and read that user's invoice. It then uses `SUPABASE_SERVICE_ROLE_KEY` only inside the Edge Function to call two narrowly scoped database RPCs that write the private delivery ledger. The service-role key must exist only as a Supabase server secret; never put it in `config.js`, Android assets, GitHub, or chat.

## Database ledger
The live project now has `private.erp_whatsapp_invoice_deliveries`, protected by RLS and with all direct access revoked from `anon` and `authenticated`. Two server-only RPCs, `public.erp_wa_claim_invoice_delivery` and `public.erp_wa_update_invoice_delivery`, perform atomic claim/status updates and are executable only by `service_role`. The old `supabase/proposals/whatsapp-image-delivery-ledger.sql` is obsolete and must not be applied.

## Client auto-send
`config.js` has `WA_AUTO_SEND_ENABLED=false`. Keep it false until the server secrets, approved image template, delivery-ledger table, and Meta test-number acceptance tests are complete. A manual send control is also available on each completed invoice.

## Important
- Only Egyptian mobile numbers beginning 010, 011, 012, or 015 are accepted by this first iteration.
- WhatsApp business-initiated messages require a valid approved template. The template must contain an IMAGE header.
- This branch has not been deployed, merged, or connected to live WhatsApp credentials.


## Deployment and test gate
Do not deploy this function until the Supabase Edge Function secret `SUPABASE_SERVICE_ROLE_KEY` is configured securely and the WhatsApp Cloud API secrets plus approved IMAGE-header template are available. Keep `WA_SEND_ENABLED=false` during deployment and initial smoke checks. A real message test requires explicit owner approval and a designated test recipient. Never paste secrets into chat or commit them to GitHub.
