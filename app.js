(() => {
  const SHOP_PHONE = "201110103452";
  const $ = (s) => document.querySelector(s);
  const grid = $("#product-grid"), status = $("#status"), count = $("#product-count");
  let products = [], selectedCategory = "الكل";
  $("#year").textContent = new Date().getFullYear();

  document.querySelectorAll("[data-whatsapp]").forEach(a => {
    a.href = `https://wa.me/${SHOP_PHONE}?text=${encodeURIComponent("السلام عليكم، عايز أستفسر عن منتجات الجباس فون.")}`;
    a.target = "_blank"; a.rel = "noopener noreferrer";
  });

  function escapeHtml(value="") {
    return String(value).replace(/[&<>"']/g, ch => ({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;","'":"&#39;"}[ch]));
  }
  function money(value) {
    const n = Number(value);
    return Number.isFinite(n) ? `${n.toLocaleString("ar-EG")} ج.م` : "السعر عند الاستفسار";
  }
  function render() {
    const q = $("#search").value.trim().toLocaleLowerCase("ar");
    let list = products.filter(p => {
      const text = [p.name,p.category,p.description,p.specs,p.condition].filter(Boolean).join(" ").toLocaleLowerCase("ar");
      const categoryMatch = selectedCategory === "الكل" ||
        (selectedCategory === "موبايلات جديدة" && /جديد|new/i.test(`${p.category} ${p.condition}`)) ||
        (selectedCategory === "موبايلات مستعملة" && /مستعمل|used/i.test(`${p.category} ${p.condition}`)) ||
        (selectedCategory === "إكسسوارات" && /إكسسوار|اكسسوار|accessor/i.test(p.category||"")) ||
        (selectedCategory === "عروض" && (p.old_price && Number(p.old_price) > Number(p.price) || p.badge));
      return categoryMatch && text.includes(q);
    });
    const sort = $("#sort").value;
    if (sort === "price-asc") list.sort((a,b)=>Number(a.price)-Number(b.price));
    if (sort === "price-desc") list.sort((a,b)=>Number(b.price)-Number(a.price));
    if (sort === "newest") list.sort((a,b)=>new Date(b.created_at||0)-new Date(a.created_at||0));
    count.textContent = `${list.length.toLocaleString("ar-EG")} منتج`;
    grid.innerHTML = list.map(p => {
      const name = escapeHtml(p.name || "منتج");
      const image = p.image ? `<img src="${escapeHtml(p.image)}" alt="${name}" loading="lazy" onerror="this.remove()">` : `<span class="placeholder">📱</span>`;
      const badge = p.badge ? `<span class="badge">${escapeHtml(p.badge)}</span>` : "";
      const old = p.old_price && Number(p.old_price)>Number(p.price) ? `<span class="old-price">${money(p.old_price)}</span>` : "";
      const specs = escapeHtml(p.specs || p.description || p.condition || "اسألنا عن التفاصيل");
      const stock = Number(p.quantity)>0 ? `متاح: ${Number(p.quantity).toLocaleString("ar-EG")}` : "التوافر يُرجى تأكيده";
      const msg = encodeURIComponent(`السلام عليكم، عايز أستفسر عن ${p.name || "منتج"}${p.price ? " بسعر "+p.price+" جنيه" : ""}.`);
      return `<article class="product-card"><div class="product-image">${image}${badge}</div><div class="product-info"><span class="product-category">${escapeHtml(p.category||"منتجات الجباس فون")}</span><h3>${name}</h3><div class="specs">${specs}</div><div class="prices"><span class="price">${money(p.price)}</span>${old}</div><div class="stock">${stock}</div><a class="product-wa" target="_blank" rel="noopener noreferrer" href="https://wa.me/${SHOP_PHONE}?text=${msg}">اسأل عن المنتج على واتساب</a></div></article>`;
    }).join("");
    if (!list.length) {
      status.hidden = false;
      status.textContent = products.length ? "مفيش منتجات مطابقة للبحث أو القسم ده." : "لسه مفيش منتجات مضافة. هتظهر هنا لما تضيفها لجدول products في Supabase.";
    } else status.hidden = true;
  }
  document.querySelectorAll(".cat").forEach(btn => btn.addEventListener("click", () => {
    document.querySelectorAll(".cat").forEach(b=>b.classList.remove("active"));
    btn.classList.add("active"); selectedCategory=btn.dataset.category; render();
  }));
  $("#search").addEventListener("input", render);
  $("#sort").addEventListener("change", render);

  async function init() {
    if (!window.SUPABASE_URL || !window.SUPABASE_PUBLISHABLE_KEY) {
      status.hidden = false;
      status.innerHTML = "الموقع جاهز للتوصيل، لكن إعدادات Supabase لسه ما اتحطتش في <b>config.js</b>. بعد إدخال عنوان المشروع والمفتاح العام هنعرض المنتجات الحقيقية.";
      count.textContent = "بانتظار إعداد الاتصال";
      return;
    }
    if (!window.supabase?.createClient) {
      status.textContent = "تعذر تحميل مكتبة الاتصال. اتأكد من الإنترنت ثم أعد تحميل الصفحة.";
      return;
    }
    try {
      const client = window.supabase.createClient(window.SUPABASE_URL, window.SUPABASE_PUBLISHABLE_KEY);
      const {data,error} = await client.from("products").select("id,name,category,price,old_price,quantity,specs,condition,image,badge,description,created_at").order("created_at",{ascending:false});
      if (error) throw error;
      products = data || [];
      render();
    } catch (err) {
      status.hidden = false;
      status.textContent = `تعذر تحميل المنتجات من Supabase. راجع إعدادات الاتصال وسياسة العرض. التفاصيل: ${err.message || "خطأ غير معروف"}`;
      count.textContent = "تعذر الاتصال";
    }
  }
  init();
})();
