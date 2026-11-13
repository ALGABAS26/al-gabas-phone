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

The function uses the Supabase-provided `SUPABASE_URL` and `SUPABASE_PUBLISHABLE_KEYS` (or legacy `SUPABASE_ANON_KEY`) environment values. It does not require a service-role key.

## Required database prerequisite
Review `supabase/proposals/whatsapp-image-delivery-ledger.sql`. It is deliberately **not a migration** and has not been applied. Generate a real migration with the Supabase CLI after explicit approval; never run the proposal on production without reviewing its effects.

## Client auto-send
`config.js` has `WA_AUTO_SEND_ENABLED=false`. Keep it false until the server secrets, approved image template, delivery-ledger table, and Meta test-number acceptance tests are complete. A manual send control is also available on each completed invoice.

## Important
- Only Egyptian mobile numbers beginning 010, 011, 012, or 015 are accepted by this first iteration.
- WhatsApp business-initiated messages require a valid approved template. The template must contain an IMAGE header.
- This branch has not been deployed, merged, or connected to live WhatsApp credentials.
