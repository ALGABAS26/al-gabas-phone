# AG system — WhatsApp image and Windows integration gates

Status: prototype code only. This branch is not deployed, merged, or enabled for live sending.

## Verified production baseline
- Android/web uses the existing Supabase project configured in `config.js`.
- Sales invoices are created by `public.erp_create_sale`; invoice and item tables have RLS enabled and owner-scoped access.
- The current invoice print flow uses the signed-in Supabase client and browser printing.
- The repository's existing Android build copies the `accounting` web app into the Capacitor wrapper.

## WhatsApp sale invoice image prototype
- The UI renders a PNG invoice image from the signed-in user's invoice, items, and shop settings.
- The Edge Function verifies the Supabase user token, invoice ownership, completed status, stored customer phone, and presence of invoice items.
- The destination number is always read from `erp_sales_invoices.customer_phone`; callers cannot choose a recipient.
- The image is uploaded to WhatsApp Cloud API media storage and sent through an approved WhatsApp template with an IMAGE header.
- The delivery ledger uses a unique owner/invoice/type key. Accepted, processing, and unknown attempts are blocked from automatic resend. Only a definite provider rejection can be retried.
- Auto-send is disabled in client config and server secrets by default. The manual control is a prototype only.

### Required setup before testing
1. Review `supabase/proposals/whatsapp-image-delivery-ledger.sql`; it is a proposal, not an applied migration.
2. Create a proper migration using the Supabase CLI after explicit approval; do not execute the proposal on production without review. Verify the table is exposed through the Data API settings, since new public tables are not automatically exposed by default.
3. Deploy the Edge Function only after review and after the ledger exists.
4. Configure server-only secrets: `WA_SEND_ENABLED=false`, `WA_ACCESS_TOKEN`, `WA_PHONE_NUMBER_ID`, `WA_IMAGE_TEMPLATE_NAME`, `WA_TEMPLATE_LANGUAGE`, and optionally `WA_GRAPH_API_VERSION`.
5. The Meta template must be approved and have an IMAGE header. Use a Meta test sender and a test recipient first.
6. Test accepted, rejected, timeout/unknown, retry, duplicate, invalid phone, cancelled invoice, and cross-owner invoice cases.
7. Enable `WA_AUTO_SEND_ENABLED=true` only after the end-to-end acceptance tests pass and the owner explicitly approves live sending.

### Safety boundaries
- No Meta token or Supabase secret/service-role key is stored in GitHub or client config.
- No live database DDL, RLS, grants, user accounts, or shop data were changed.
- No function has been deployed and no WhatsApp message has been sent.
- A network timeout after the send request is recorded as unknown and is not automatically retried to avoid duplicate invoices.

## Windows desktop
- Keep Supabase as the single source of truth shared with Android.
- Prototype Tauri around the existing static HTML/JS application.
- Reuse the same Supabase Auth and RLS model; keep session material in OS-protected storage.
- Do not introduce a second business database or replication layer.
- Validate printing, Arabic text, barcode/camera fallback, offline/reconnect, session expiry, installer upgrade/uninstall, and cross-platform data consistency.
- Do not publish a signed installer or release until signing credentials and explicit release approval exist.

## Not yet complete
- WhatsApp template/credentials setup, production deployment, delivery webhook updates, and live acceptance testing.
- Windows Tauri shell, installer, CI workflow, and Windows acceptance tests.
