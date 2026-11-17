# WhatsApp sale invoice image — disabled integration scaffold

This is a prepared integration, not an active sending service. The Edge Function is not deployed and `WA_SEND_ENABLED` must remain unset or `false`.

## What is already implemented in code
- The Android/web client can render a completed sale invoice as a PNG image using invoice rows read under the signed-in user's existing RLS.
- The Edge Function validates the caller JWT, invoice ownership, completed status, customer phone, and invoice items.
- Server-side code is prepared to upload the image to WhatsApp Cloud API and send it using an approved IMAGE-header template.
- A private delivery ledger interface is used by the function to claim an invoice send and update its status. The matching SQL proposal in this repository is not approved for production and has not been applied as part of this work.
- A strict server-side kill switch now permits sending only when `WA_SEND_ENABLED` is exactly `true`. Missing, empty, `false`, or any other value disables all outbound WhatsApp requests.
- Automatic invoice sending remains disabled in the client through `WA_AUTO_SEND_ENABLED=false`.

## What is not active yet
- The Edge Function has not been deployed.
- Meta app, WhatsApp Business account, phone number ID, access token, and approved template have not been configured.
- The delivery-ledger SQL/RPC requirements must be reviewed and tested in a separate database before any deployment.
- No PDF generation or PDF-document message flow is implemented yet; the current prototype is an invoice PNG image.
- No real WhatsApp message has been sent.

## Server secrets required later
- `WA_SEND_ENABLED=false` during deployment and acceptance checks.
- `WA_ACCESS_TOKEN`
- `WA_PHONE_NUMBER_ID`
- `WA_IMAGE_TEMPLATE_NAME` (approved WhatsApp template with an IMAGE header)
- `WA_TEMPLATE_LANGUAGE` (for example `ar`)
- `WA_GRAPH_API_VERSION` (defaults to `v25.0`)
- Supabase `SUPABASE_SERVICE_ROLE_KEY` only inside the Edge Function environment, never in `config.js`, Android assets, GitHub, or chat.

The function uses the caller JWT and Supabase publishable key to verify the signed-in user and read that user's invoice. The service-role key is intended only for narrowly scoped server-side ledger RPCs. Never expose it in a public client.

## Later activation sequence
1. Configure Meta and obtain a test phone number, phone number ID, and token.
2. Create and approve the IMAGE-header template.
3. Review the delivery-ledger schema and RPCs in a separate test database.
4. Deploy the Edge Function with `WA_SEND_ENABLED=false`.
5. Test authorization, invoice ownership, invalid numbers, duplicate claims, and error paths without contacting real recipients.
6. With explicit owner approval, enable the server flag and send one message to a designated test recipient.
7. Keep client auto-send disabled until the single-message test and delivery webhook are verified.

## Local validation
Run:
```sh
deno test --allow-read supabase/functions/send-sale-invoice-image/validation_test.ts supabase/functions/notify-maintenance-ready/validation_test.ts
```
The tests cover phone normalization, PNG validation, timeout behavior, template construction, and the disabled-by-default send gate. They do not deploy functions, contact Meta, or send WhatsApp messages.
