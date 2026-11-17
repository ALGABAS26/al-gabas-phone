# WhatsApp Cloud API — disabled integration scaffold

This integration is prepared in code only. The sending Edge Functions are not deployed and `WA_SEND_ENABLED` must remain unset or `false`.

## Implemented in code
- The Android/web client can render a completed sale invoice as a PNG image using invoice rows read under the signed-in user's existing RLS.
- The sale-invoice Edge Function validates the caller JWT, invoice ownership, completed status, customer phone, and invoice items.
- Server-side code is prepared to upload the image to WhatsApp Cloud API and send it using an approved IMAGE-header template.
- A private delivery ledger interface claims an invoice send and records the provider message ID and status.
- A strict server-side kill switch permits sending only when `WA_SEND_ENABLED` is exactly `true`.
- A second client-side kill switch `WA_CLIENT_SEND_ENABLED=false` blocks manual invocation before any Edge Function request. Automatic sending remains disabled through `WA_AUTO_SEND_ENABLED=false`.
- A new `whatsapp-meta-webhook` Edge Function handles Meta's GET subscription challenge and verifies POST signatures with HMAC-SHA256 over the exact raw body using `WA_META_APP_SECRET`.
- The webhook extracts `sent`, `delivered`, `read`, and `failed` status updates and calls a narrowly scoped service-role RPC. The SQL proposal updates both invoice and maintenance ledgers and is `supabase/proposals/whatsapp-meta-webhook-rpc.sql`.
- Webhook signature, parsing, and status mapping tests are included in CI.

## Important activation blockers
- None of the WhatsApp functions have been deployed.
- Meta app, WhatsApp Business account, phone number ID, access token, app secret, verification token, and approved templates are not configured.
- The webhook RPC proposal has **not** been applied. It requires both private ledger tables (invoice ledger already exists in the current project; maintenance ledger is created by `maintenance-deposit-and-whatsapp-ready.sql`). Review and test the combined RPC in a separate test database before the webhook can update statuses.
- The production database currently has the invoice ledger and claim/update RPCs, but does not have the maintenance-notification ledger or its RPCs. The maintenance SQL remains proposal-only.
- The sale/purchase print view is A4-ready and the system print dialog can save a PDF manually. This is not server-generated PDF or an automatic WhatsApp document attachment; the current invoice-message prototype still sends PNG.
- No real WhatsApp message has been sent.

## Server secrets required later
- `WA_SEND_ENABLED=false` during deployment and acceptance checks.
- `WA_ACCESS_TOKEN`
- `WA_PHONE_NUMBER_ID`
- `WA_IMAGE_TEMPLATE_NAME` (approved IMAGE-header template)
- `WA_MAINTENANCE_READY_TEMPLATE_NAME` (approved maintenance Utility template)
- `WA_TEMPLATE_LANGUAGE=ar`
- `WA_GRAPH_API_VERSION` (defaults to `v25.0`)
- `WA_META_APP_SECRET` (Meta app secret, server only)
- `WA_WEBHOOK_VERIFY_TOKEN` (random verification string chosen by the owner)
- Supabase `SUPABASE_SERVICE_ROLE_KEY` only inside Edge Function secrets, never in client config, Android assets, GitHub, or chat.

## Activation sequence
1. Configure a Meta test app and test WhatsApp phone number, then obtain its phone number ID, token, and app secret.
2. Create and approve the image-header invoice template and the maintenance-ready Utility template.
3. Review and test `maintenance-deposit-and-whatsapp-ready.sql` and `whatsapp-meta-webhook-rpc.sql` in a disposable database; this also adds the atomic maintenance-ticket + deposit-to-cashbox RPC.
4. Deploy the functions with sending still disabled. Configure the webhook callback URL and verify token in Meta.
5. Test signature rejection, valid signatures, unknown message IDs, duplicate status deliveries, and monotonic status transitions without sending to real recipients.
6. With explicit owner approval, enable the server flag and send one message to a designated test recipient.
7. Keep client automatic sending disabled until the single-message test and webhook status updates are verified.

## Local validation
Run:
```sh
deno test --allow-read supabase/functions/send-sale-invoice-image/validation_test.ts supabase/functions/notify-maintenance-ready/validation_test.ts supabase/functions/whatsapp-meta-webhook/validation_test.ts
```
These tests do not deploy functions, contact Meta, or send WhatsApp messages.
