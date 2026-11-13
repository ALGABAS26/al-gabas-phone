# AG system — WhatsApp and Windows implementation gates

Status: engineering preparation only. This document does not change the production database, authentication, shop data, or deployed applications.

## Verified current behavior

- Sales invoices are created by `public.erp_create_sale` and contain `owner_id`, `customer_phone`, totals, status, and timestamps.
- Invoice items are stored in `public.erp_sales_invoice_items` with `owner_id` and `invoice_id`.
- The current print path in `accounting/app.js` loads invoice, items, and shop settings through the signed-in Supabase client, then writes an HTML document and calls `window.print()`.
- The browser app uses Supabase Auth and a publishable key. It must never receive the Supabase service-role key or Meta access token.
- The repository has no Supabase Edge Function project, no PDF generator/font asset, no WhatsApp delivery ledger, and no Tauri/Electron desktop project or Windows workflow.

## WhatsApp implementation contract

The first implementation must be a Supabase Edge Function (or equivalent trusted backend), not a direct client-to-Meta call.

1. Require a valid Supabase user access token; resolve the user from the token rather than accepting an owner ID from the request.
2. Fetch the requested invoice and its items using a user-scoped Supabase client so existing RLS remains in force. Require `invoice.owner_id = auth.uid()` and `invoice.status = 'completed'`.
3. Derive the destination phone from the stored invoice. Normalize and validate the number server-side; do not accept an arbitrary destination supplied by the client.
4. Generate the PDF on the server. Arabic text must use an embedded Arabic-capable font; the default PDF standard fonts are not sufficient. Include the shop name, invoice number/date, customer, item rows, totals, and a clear invoice identifier.
5. Store the PDF in a private bucket under a deterministic owner/invoice path. Do not create public object URLs.
6. Create a persistent send ledger with a unique idempotency key (at minimum owner + invoice + delivery intent), state transitions, provider message ID, timestamps, and sanitized error details. A retry must not send a second copy after an accepted provider response.
7. Send using WhatsApp Cloud API from the backend only. Prefer a pre-approved document-header template for business-initiated conversations; template name, language, and parameter mapping must match the approved Meta template. Never assume an open 24-hour customer-service window.
8. Verify webhook signatures and process delivery statuses idempotently. Never log tokens, full phone numbers, PDF contents, or customer data.
9. Default sending to disabled until the owner configures Meta credentials and an explicit server-side enable flag. Use only a Meta test number and synthetic invoices during acceptance testing.

### Required server secrets/configuration

- Supabase project URL and publishable key for user-scoped access; service-role key only if a separately reviewed backend operation truly requires it.
- Meta WhatsApp access token, phone-number ID, Graph API version, app secret for webhook verification.
- Approved document template name and language.
- A private storage bucket and a persistent delivery-ledger schema.
- An explicit send-enable flag, disabled by default.

No production secrets belong in GitHub files, client configuration, build artifacts, or chat messages.

## Windows implementation contract

1. Keep Supabase as the single source of truth. Do not introduce a second business database or custom replication layer.
2. Prototype Tauri first because the existing application is a static HTML/JS frontend; evaluate Electron only if native plugin compatibility or printing fails.
3. Reuse the same authentication flow and authorization rules. Store session material using OS-protected storage; do not hardcode credentials.
4. Add a Windows CI job that builds a signed installer only when signing secrets are configured. Do not publish releases automatically during the prototype.
5. Test install, upgrade, uninstall, offline/reconnect behavior, invoice printing, Arabic font rendering, camera/barcode fallback, and session expiry.
6. Keep Android and Windows on the same web application build where feasible, with platform-specific adapters isolated from business logic.

## Acceptance tests before enabling either feature

- A user cannot request or send another user's invoice, including by guessing an invoice UUID.
- Cancelled invoices cannot be sent.
- Missing/invalid customer phone, missing PDF, absent template configuration, or disabled sending fails closed.
- Repeated requests with the same idempotency key result in one provider send.
- Provider rejection, timeout, retry, and webhook out-of-order delivery do not create duplicate sends or false delivered states.
- PDF output contains all invoice rows and totals and renders Arabic correctly.
- No Meta token or service-role key appears in browser bundles, Android APK/AAB, Windows installer, logs, or Git history.
- Windows and Android read/write the same central records and never silently fork data.
- Existing Android login, sales, inventory, cash, returns, and printing regressions pass.

## Explicit non-goals for this branch

- No production SQL, grants, RLS, user accounts, login changes, shop data changes, or live WhatsApp sends.
- No modification to the current visual identity.
- No deployment, release publication, or merge to `main`.

## External prerequisites that code alone cannot supply

- A Meta Business portfolio, approved WhatsApp Business sender/phone number, Cloud API credentials, and an approved document template.
- A separate Supabase test project with synthetic data, a private storage bucket, and a reviewed delivery-ledger migration.
- An Arabic-capable PDF font licensed for bundling.
- Windows signing certificate/secrets if a trusted signed installer is required.

Until these prerequisites and the acceptance tests are available, the integration must remain disabled. This is a safety gate, not a claim that WhatsApp or Windows support is complete.
