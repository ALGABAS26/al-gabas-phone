-- إصلاح خطأ products_category_check عند حفظ تصنيف جديد.
-- شغّل هذا الملف مرة واحدة في Supabase Dashboard > SQL Editor.
-- التعديل يسمح بأي اسم قسم نصّي غير فارغ، مع السماح بـ NULL.
ALTER TABLE public.products
  DROP CONSTRAINT IF EXISTS products_category_check;

ALTER TABLE public.products
  ADD CONSTRAINT products_category_check
  CHECK (category IS NULL OR length(btrim(category)) > 0);
