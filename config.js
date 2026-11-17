/*
  إعدادات الاتصال بقاعدة بيانات Supabase.
  ضع Project URL والمفتاح العام (publishable key أو anon key) من إعدادات مشروعك.
  لا تضع service_role أو secret key هنا أبدًا.
*/
window.SUPABASE_URL = "https://oplkdaywkvunttnhimwz.supabase.co";
window.SUPABASE_PUBLISHABLE_KEY = "sb_publishable_oVsd1fI6Mo3Tdkz1cFDdNw_iUCb7kEc";

// Client-side safety switch. Keep disabled until Meta setup, server deployment and acceptance tests.
window.WA_CLIENT_SEND_ENABLED = false;
// Automatic invoice delivery requires both client and server switches to be explicitly enabled.
window.WA_AUTO_SEND_ENABLED = false;
