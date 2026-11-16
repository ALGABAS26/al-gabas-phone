# AG System SaaS control plane — implementation contract

## User experience
1. Public registration collects shop name, owner's name, email, mobile, and password.
2. Supabase Auth creates the identity; the shop creation request runs server-side and creates a pending shop, owner membership in pending/invited state, and a pending trial/license record.
3. The registrant sees "طلبك قيد المراجعة" and cannot open ERP pages before approval.
4. The platform owner has a separate admin route with shop search, shop details, status, plan, created date, and actions: Activate, Suspend, Reactivate, Extend trial, Cancel.
5. Suspension is immediate at database policy level and logged with actor, reason, timestamp, previous status, and new status.
6. A shop owner can invite staff later; role permissions are shop-scoped.

## Security architecture
- Auth identity: Supabase Auth.
- Tenant boundary: `shop_id` on every ERP business row.
- Membership authorization: `erp_shop_memberships` with active status and role.
- License state: `erp_shops.status` plus `erp_shop_subscriptions.status/expires_at/grace_until`.
- Platform administrator: immutable Auth UUID allowlist held only in Edge Function secrets. Never use `user_metadata`, client-side flags, or an email typed into a form as authority.
- Admin API: Edge Function verifies caller JWT using `auth.getUser()`, checks the UUID allowlist, uses service-role only inside the function, and appends an audit row.
- RLS: every exposed ERP table must require an active membership and active shop/license. Direct client writes cannot set another shop's `shop_id`.
- Offline Windows/Android clients must revalidate the license with the backend before every protected sync/write; a locally cached "active" flag is not authority.

## Important migration caveat
The current production database has `shop_id` columns but all inspected ERP business-table policies still use `owner_id = auth.uid()`. Existing application CRUD and posting RPCs also still write by owner_id. Therefore, simply adding a signup screen or setting `erp_shops.status='suspended'` would NOT securely stop an existing shop. A complete multi-tenant migration must update all RLS policies, direct CRUD paths, and posting RPCs together.

## Windows desktop scaffold (in progress)
- A Tauri 2.12.x desktop wrapper has been added in `src-tauri/`.
- A cross-platform Node asset-preparation script keeps the shared accounting UI and public Supabase config in the correct relative paths.
- A Windows GitHub Actions workflow builds MSI and NSIS installers and uploads CI artifacts only; it does not publish a GitHub Release.
- The first Windows build is running in CI. Installer creation, launch/runtime testing, printing, update strategy, code signing, and live synchronization remain unverified.
- WebView2 currently uses the small online bootstrapper mode; a fully offline installer would be substantially larger and needs a separate decision.

## Separate workstreams still pending
- Test-only SQL migration and RLS policy suite.
- Meta-approved maintenance-ready and PDF document templates, test-number verification, server-only send.
- Server-side PDF generation with embedded Arabic font, immutable invoice snapshot, and WhatsApp document media/template delivery.
- Meta webhook signature verification and idempotent delivered/read/failed status updates.
- Tauri Windows shell (preferred initial choice because the UI is already HTML/CSS/JS and Capacitor-based; keep shared UI and Supabase APIs). Evaluate Windows signing/installer, auto-update, printing, and offline behavior before release.
- Windows installer and end-to-end synchronization tests against the same central Supabase project.
- Platform-owner SaaS console and shop onboarding/licensing.

No production deployment or database changes are authorized by this document.
