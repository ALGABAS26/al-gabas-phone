# AG System — الحالة الحالية والخطوات المتبقية

آخر مراجعة: 17 نوفمبر 2026.

## ما تم تنفيذه بالفعل

- قاعدة الإنتاج **AL GABAS PHONE** وقاعدة الاختبار **AL GABAS** تحتويان على مخطط التطبيق وترقيات الصيانة والعربون وسجلات واتساب ودوال RPC اللازمة.
- اختبارات SQL المقترحة نجحت على PostgreSQL مؤقت داخل CI، كما نُفذت اختبارات سيناريوهات العربون وحالات سجل واتساب على قاعدة الاختبار.
- نُشرت وظائف Edge Functions التالية على قاعدة الاختبار والإنتاج:
  - `send-sale-invoice-pdf`
  - `notify-maintenance-ready`
  - `whatsapp-meta-webhook`
- دالتا إرسال التطبيق تتطلبان JWT، والـWebhook يستخدم تحقق Meta الخاص به مع `verify_jwt=false`.
- تم تشديد صلاحيات `rls_auto_enable()` وإزالة صلاحية التنفيذ المجهول عن `erp_my_shop_profile()`، مع إبقاء صلاحية المستخدم المسجل. كما ثُبّت `search_path` لدالتي IMEI.
- لم يتم إرسال أي رسالة حقيقية، ولم يتم تفعيل مفاتيح الإرسال. لا تعِد تشغيل ملفات SQL المقترحة على الإنتاج أو الاختبار؛ التغييرات موجودة بالفعل.
- مفتاحا العميل `WA_CLIENT_SEND_ENABLED` و`WA_AUTO_SEND_ENABLED` ما زالا `false` في `config.js` عمدًا حتى انتهاء اختبار Meta.
- طلب GitHub رقم 3 ما زال مفتوحًا كمسودة ولم يتم دمجه.

## ما يحتاجه مالك المشروع الآن

### 1) إعداد Meta باستخدام رقم تجريبي فقط

1. افتح Meta for Developers وأنشئ تطبيقًا أو استخدم تطبيقًا تملكه.
2. أضف منتج WhatsApp واربطه بحساب WhatsApp Business المناسب.
3. ابدأ برقم Meta التجريبي والمستلم التجريبي. لا تنقل رقم واتساب الحالي ولا تحذف التطبيق الرسمي من الهاتف.
4. جهّز القيم التالية من لوحة Meta: Phone Number ID وAccess Token وApp Secret.
5. أنشئ قالب Utility عربي باسم `ag_sale_invoice` ورأسه Document دون متغيرات في جسم الرسالة.
6. أنشئ قالب Utility عربي باسم `ag_maintenance_ready`، وفي جسمه ثلاثة متغيرات بالترتيب: اسم العميل، اسم الجهاز، رقم التذكرة. انتظر اعتماد القالبين.

### 2) إعداد Webhook في Meta

عنوان Callback URL للإنتاج:

`https://oplkdaywkvunttnhimwz.supabase.co/functions/v1/whatsapp-meta-webhook`

عنوان Callback URL للاختبار:

`https://thxykjapwovlzxctddcx.supabase.co/functions/v1/whatsapp-meta-webhook`

اختر رمز تحقق عشوائيًا طويلًا بنفسك، واحفظه في مدير كلمات المرور. أدخل عنوان الـCallback ورمز التحقق في Meta، واشترك في حقل `messages`.

### 3) إضافة أسرار Meta في Supabase

ابدأ بمشروع الاختبار **AL GABAS** فقط: Dashboard → Edge Functions → Secrets.

أضف الأسماء التالية، وضع القيم من حساب Meta مباشرة داخل Supabase. لا ترسل القيم السرية في المحادثة:

- `WA_SEND_ENABLED` = `false` في البداية
- `WA_ACCESS_TOKEN`
- `WA_PHONE_NUMBER_ID`
- `WA_DOCUMENT_TEMPLATE_NAME` = `ag_sale_invoice`
- `WA_MAINTENANCE_READY_TEMPLATE_NAME` = `ag_maintenance_ready`
- `WA_META_APP_SECRET`
- `WA_WEBHOOK_VERIFY_TOKEN` = رمز التحقق الذي اخترته
- `WA_TEMPLATE_LANGUAGE` = `ar`
- `WA_GRAPH_API_VERSION` = `v25.0`

Supabase يوفّر مفاتيح المشروع الافتراضية للدوال، ومنها `SUPABASE_SERVICE_ROLE_KEY`. لا تضع مفتاح Service Role في التطبيق أو المحادثة أو أي ملف GitHub، ولا تشاركه مع أي شخص.

### 4) الاختبار قبل تفعيل الإنتاج

بعد ضبط أسرار الاختبار، أخبرني أن الإعداد اكتمل دون إرسال أي قيمة سرية. سنراجع تحقق Webhook وسجلات الدوال أولًا. لا نفعّل `WA_SEND_ENABLED=true` على الاختبار إلا عند الاستعداد لاختبار رسالة واحدة إلى مستلم Meta التجريبي وبموافقتك الصريحة.

بعد نجاح اختبار الفاتورة PDF وإشعار الصيانة وحالات delivered/read، نضيف أسرار Meta إلى مشروع الإنتاج مع إبقاء الإرسال مغلقًا حتى الموافقة النهائية.

### 5) تفعيل التطبيق والإرسال التلقائي

بعد نجاح الاختبار فقط، سأحدّث `config.js` إلى:
- `WA_CLIENT_SEND_ENABLED = true` لتفعيل زر إرسال PDF.
- `WA_AUTO_SEND_ENABLED = true` لإرسال PDF تلقائيًا بعد حفظ فاتورة البيع.

ثم سأعيد بناء APK/AAB ونسخ Windows. يظل مفتاح الخادم `WA_SEND_ENABLED` هو حاجز الأمان الأخير، ولا نفعّله في الإنتاج إلا بعد مراجعتك.

## ملاحظات مهمة

- PDF الفاتورة متعدد الصفحات، لكنه يستخدم صورًا داخل PDF للحفاظ على تشكيل العربية؛ النص غير قابل للتحديد والبحث.
- لا يتم ترحيل رقم واتساب الحالي أو العبث بالتطبيق الرسمي على الهاتف.
- لا يوجد نشر إصدار عام أو دمج PR تلقائيًا.
- لا تُرسل أي مفاتيح أو Tokens أو App Secret أو Service Role في المحادثة أو GitHub.
