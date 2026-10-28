ALGABAS STORE
Arabic storefront for Algabas Store. Includes the static storefront, product detail view, cart, admin page, Supabase client configuration, and local category photography in assets/.
Deploy
Upload the contents of this directory to the existing GitHub Pages repository while preserving the directory structure. Then verify the deployed site and manually test product loading, admin sign-in and CRUD, category filtering, product detail refresh/back navigation, cart persistence, and WhatsApp checkout.
Validation status
Local JavaScript syntax checks and local image-file validation passed. Live Supabase/admin/CDN checks and automated browser checks were not possible in the current environment and must be completed manually after deployment.
config.js should contain only the Supabase URL and public publishable/anon key. Never put a service_role or secret key in public client-side files.
