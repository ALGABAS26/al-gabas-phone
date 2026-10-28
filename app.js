(() => {
  const SHOP_PHONE = "201110103452";
  const $ = s => document.querySelector(s);
  const $$ = s => document.querySelectorAll(s);
  
  let products = [], cart = [], selectedCategory = "الكل";

  // تفعيل روابط الواتساب التلقائية
  $$("[data-whatsapp]").forEach(a => {
    a.href = `https://wa.me/${SHOP_PHONE}?text=${encodeURIComponent("السلام عليكم، عايز أستفسر عن منتجات الجباس فون.")}`;
    a.target = "_blank"; a.rel = "noopener noreferrer";
  });

  // التنقل بين الشاشات والصفحات (Views)
  function switchView(viewId) {
    $$(".page-view").forEach(v => v.classList.remove("active-view"));
    const target = $(`#${viewId}`);
    if (target) {
      target.classList.add("active-view");
      window.scrollTo({ top: 0, behavior: "smooth" });
    }
  }

  // ربط الأزرار في الهيدر والنافذة السفلية والأقسام
  document.addEventListener("click", e => {
    const targetEl = e.target.closest("[data-target]");
    if (targetEl) {
      const viewName = targetEl.dataset.target;
      if (viewName === "home") switchView("home-view");
      if (viewName === "categories-page") { switchView("categories-page-view"); renderProducts(); }
      if (viewName === "offers-page") switchView("offers-page-view");
      if (viewName === "maintenance-page") switchView("maintenance-page-view");
      if (viewName === "contact-page") switchView("home-view");
    }

    // الانتقال من بطاقات الأقسام الطولية في الصفحة الرئيسية
    const vCard = e.target.closest(".v-section-card");
    if (vCard && vCard.dataset.category) {
      selectedCategory = vCard.dataset.category;
      switchView("categories-page-view");
      renderProducts();
    }
  });

  // التحكم في السلة الجانبية
  $("#open-cart-btn").onclick = () => $("#cart-overlay").classList.add("open");
  $("#close-cart-btn").onclick = () => $("#cart-overlay").classList.remove("open");
  $("#cart-overlay").onclick = (e) => { if (e.target === $("#cart-overlay")) $("#cart-overlay").classList.remove("open"); };

  function updateCartUI() {
    $("#cart-count").textContent = cart.reduce((acc, item) => acc + item.qty, 0);
    const list = $("#cart-items-list");
    if (!cart.length) {
      list.innerHTML = `<div class="empty-state-notice" style="border:0; background:none;">لم تقترن بأي منتج بعد. اختر منتجك المفضّل!</div>`;
      $("#cart-total-price").textContent = "0 ج.م";
      return;
    }
    let total = 0;
    list.innerHTML = cart.map((item, idx) => {
      total += (item.price * item.qty);
      return `<div class="cart-item-row">
        <div><b>${item.name}</b><div style="font-size:12px; color:#94a3b8">${item.price} ج.م × ${item.qty}</div></div>
        <button style="background:#c92736; color:white; border:0; padding:4px 8px; border-radius:4px; cursor:pointer;" onclick="window.removeFromCart(${idx})">حذف</button>
      </div>`;
    }).join("");
    $("#cart-total-price").textContent = `${total.toLocaleString("ar-EG")} ج.م`;
  }

  window.removeFromCart = (idx) => {
    cart.splice(idx, 1);
    updateCartUI();
  };

  $("#checkout-whatsapp-btn").onclick = () => {
    if (!cart.length) {
      alert("عذراً، لم تقترن بأي منتج بعد لاختياره.");
      return;
    }
    let text = "السلام عليكم، أرغب في إتمام طلب المنتجات الآتية:\n";
    cart.forEach(i => { text += `- ${i.name} (${i.price} ج.م) × ${i.qty}\n`; });
    window.open(`https://wa.me/${SHOP_PHONE}?text=${encodeURIComponent(text)}`, "_blank");
  };

  // جلب البيانات وعرضها من Supabase
  function escapeHtml(str="") { return String(str).replace(/[&<>"']/g, c => ({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;","'":"&#39;"}[c])); }
  function money(v) { const n = Number(v); return Number.isFinite(n) ? `${n.toLocaleString("ar-EG")} ج.م` : "السعر عند الاستفسار"; }

  function renderProducts() {
    const q = $("#search").value.trim().toLowerCase();
    let list = products.filter(p => {
      const matchCat = selectedCategory === "الكل" || (p.category && p.category.includes(selectedCategory));
      const matchSearch = [p.name, p.category, p.description].filter(Boolean).join(" ").toLowerCase().includes(q);
      return matchCat && matchSearch;
    });

    const sort = $("#sort").value;
    if (sort === "price-asc") list.sort((a,b) => Number(a.price) - Number(b.price));
    if (sort === "price-desc") list.sort((a,b) => Number(b.price) - Number(a.price));
    if (sort === "newest") list.sort((a,b) => new Date(b.created_at||0) - new Date(a.created_at||0));

    const grid = $("#product-grid");
    if (!list.length) {
      grid.innerHTML = `<div class="empty-state-notice">لا توجد منتجات مطابقة لهذا القسم حالياً.</div>`;
      return;
    }

    grid.innerHTML = list.map((p, idx) => {
      const img = p.image ? `<img src="${escapeHtml(p.image)}" alt="">` : `📱`;
      return `<article class="product-card" data-id="${p.id}">
        <div class="product-image">${img}</div>
        <span class="product-category">${escapeHtml(p.category || "الجباس فون")}</span>
        <h3>${escapeHtml(p.name)}</h3>
        <div class="product-price">${money(p.price)}</div>
        <button class="product-card-btn">عرض التفاصيل</button>
      </article>`;
    }).join("");

    grid.querySelectorAll(".product-card").forEach((card, i) => {
      card.onclick = () => showProductDetail(list[i]);
    });
  }

  // صفحة تفاصيل المنتج الانتقالية بدون فقاعة زوم
  function showProductDetail(p) {
    if (!p) return;
    switchView("product-detail-view");
    const container = $("#product-detail-content");
    const img = p.image ? `<img src="${escapeHtml(p.image)}" alt="">` : `📱`;
    const conditionText = p.condition ? p.condition : "جديد";
    
    container.innerHTML = `
      <div class="detail-image-box">${img}</div>
      <span class="detail-badge-condition">${escapeHtml(conditionText)}</span>
      <h2 class="detail-title">${escapeHtml(p.name)}</h2>
      <div class="detail-price">${money(p.price)}</div>
      <div class="detail-specs-list">
        <b>المواصفات والوصف:</b>
        <p>${escapeHtml(p.description || p.specs || "تواصل معنا لمعرفة كافة تفاصيل ومواصفات الجهاز.")}</p>
      </div>
      <div class="quantity-cart-row">
        <input type="number" id="detail-qty" class="quantity-input" value="1" min="1" max="10">
        <button class="add-to-cart-main-btn" id="add-to-cart-action">أضف إلى السلة</button>
      </div>
    `;

    $("#add-to-cart-action").onclick = () => {
      const qty = parseInt($("#detail-qty").value) || 1;
      cart.push({ id: p.id, name: p.name, price: Number(p.price) || 0, qty: qty });
      updateCartUI();
      $("#cart-overlay").classList.add("open");
    };
  }

  $("#back-from-detail").onclick = () => switchView("categories-page-view");
  if ($("#search")) $("#search").oninput = renderProducts;
  if ($("#sort")) $("#sort").onchange = renderProducts;

  // أزرار فلترة الأقسام
  $$(".cat-pill").forEach(btn => {
    btn.onclick = (e) => {
      $$(".cat-pill").forEach(b => b.classList.remove("active"));
      e.target.classList.add("active");
      selectedCategory = e.target.dataset.category || e.target.textContent;
      renderProducts();
    };
  });

  // تهيئة الاتصال بقاعدة البيانات عبر Supabase
  async function initApp() {
    if (!window.SUPABASE_URL || !window.SUPABASE_PUBLISHABLE_KEY || !window.supabase?.createClient) {
      console.warn("إعدادات Supabase غير مكتملة.");
      return;
    }
    try {
      const client = window.supabase.createClient(window.SUPABASE_URL, window.SUPABASE_PUBLISHABLE_KEY);
      const { data, error } = await client.from("products").select("*").order("created_at", { ascending: false });
      if (error) throw error;
      products = data || [];
      renderProducts();
    } catch (err) {
      console.error("تعذر جلب المنتجات:", err.message);
    }
  }

  initApp();
})();
        
