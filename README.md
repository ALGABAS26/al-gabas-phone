# الجباس فون | AL GABAS PHONE

موقع عربي متجاوب لعرض منتجات محل الجباس فون، مع البحث والتصفية والتواصل عبر واتساب، ومهيأ للقراءة من جدول `public.products` في Supabase.

## الملفات
- `index.html`: هيكل الموقع.
- `style.css`: التصميم المتجاوب.
- `config.js`: إعدادات Supabase العامة.
- `app.js`: تحميل المنتجات وعرضها.

## إعداد Supabase
1. افتح إعدادات مشروع Supabase وانسخ Project URL والمفتاح العام `publishable` أو `anon` القديم.
2. ضع القيم في `config.js` داخل `SUPABASE_URL` و`SUPABASE_PUBLISHABLE_KEY`.
3. لا تضع `service_role` أو أي secret key في ملفات الموقع.
4. يجب أن تكون سياسة SELECT العامة على `public.products` مفعلة. عمليات الكتابة تبقى محمية بسياسات RLS.

## النشر
ارفع الملفات إلى مستودع GitHub، ثم يمكنك نشر الموقع عبر خدمة استضافة تدعم المواقع الثابتة، مع اختيار `index.html` كصفحة البداية.
