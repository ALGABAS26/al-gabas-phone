(() => {
const SHOP_PHONE="201110103452", $=s=>document.querySelector(s);
const grid=$("#product-grid"), status=$("#status"), count=$("#product-count");
let products=[], selectedCategory="الكل";
const sectionToCategory={iphone:"آيفون",android:"أندرويد",accessories:"إكسسوارات",offers:"عروض",new:"موبايلات جديدة"};
const initialSection=new URLSearchParams(location.search).get("section");
if(sectionToCategory[initialSection]) selectedCategory=sectionToCategory[initialSection];
let cart=[];
try { const saved=JSON.parse(localStorage.getItem("algabas_cart")||"[]"); cart=Array.isArray(saved)?saved.filter(x=>x&&x.id!==undefined&&Number(x.qty)>0).map(x=>({id:x.id,qty:Math.floor(Number(x.qty))})):[]; } catch { cart=[]; }
$("#year").textContent=new Date().getFullYear();
function esc(v=""){return String(v).replace(/[&<>"']/g,c=>({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;","'":"&#39;"}[c]));}
function money(v){const n=Number(v);return Number.isFinite(n)?`${n.toLocaleString("ar-EG")} ج.م`:"السعر عند الاستفسار";}
function wa(text){return `https://wa.me/${SHOP_PHONE}?text=${encodeURIComponent(text)}`;}
document.querySelectorAll("[data-whatsapp]").forEach(a=>{a.href=wa("السلام عليكم، عايز أستفسر عن منتجات الجباس استور.");a.target="_blank";a.rel="noopener noreferrer";});
function categoryMatch(p){
 const hay=[p.name,p.category,p.description,p.specs,p.condition,p.brand,p.model].filter(Boolean).join(" ").toLocaleLowerCase("ar");
 const cat=String(p.category||"").toLocaleLowerCase("ar");
 const isAccessory=/إكسسوار|اكسسوار|accessor|جراب|case|شاحن|charger|سماعة|headphone|earbud|ساعة ذكية|smart ?watch|كابل|cable|power ?bank/i.test(hay);
 const isIphone=/iphone|آيفون|ايفون|apple|ابل|أبل/i.test(hay);
 const isAndroid=/android|أندرويد|اندرويد|samsung|سامسونج|xiaomi|شاومي|redmi|ريدمي|oppo|أوبو|vivo|فيفو|realme|ريلمي|huawei|هواوي|honor|هونر|infinix|انفنكس|tecno|تكنو|oneplus/i.test(hay);
 if(selectedCategory==="آيفون") return isIphone && !isAccessory;
 if(selectedCategory==="أندرويد") return isAndroid && !isIphone && !isAccessory;
 if(selectedCategory==="موبايلات جديدة") return !isAccessory && (isIphone||isAndroid||/موبايل|mobile|phone|هاتف/i.test(hay) || /موبايلات|موبايل|هواتف|جديد|new/i.test(cat+" "+String(p.condition||"")));
 if(selectedCategory==="إكسسوارات") return isAccessory;
 if(selectedCategory==="عروض") return (p.old_price&&Number(p.old_price)>Number(p.price))||p.badge;
 return true;
}
function render(){
 const q=$("#search").value.trim().toLocaleLowerCase("ar");
 let list=products.filter(p=>categoryMatch(p)&&[p.name,p.category,p.description,p.specs,p.condition].filter(Boolean).join(" ").toLocaleLowerCase("ar").includes(q));
 const sort=$("#sort").value;if(sort==="price-asc")list.sort((a,b)=>Number(a.price)-Number(b.price));if(sort==="price-desc")list.sort((a,b)=>Number(b.price)-Number(a.price));if(sort==="newest")list.sort((a,b)=>new Date(b.created_at||0)-new Date(a.created_at||0));
 count.textContent=`${list.length.toLocaleString("ar-EG")} منتج`;
 grid.innerHTML=list.map((p,i)=>`<article class="product-card" tabindex="0" role="button" data-product="${esc(p.id)}"><div class="product-image">${p.image?`<img src="${esc(p.image)}" alt="${esc(p.name)}" loading="lazy">`:'<span class="placeholder">الصورة غير متاحة</span>'}${p.badge?`<span class="badge">${esc(p.badge)}</span>`:""}</div><div class="product-info"><span class="product-category">${esc(p.category||"منتجات الجباس استور")}</span><h3>${esc(p.name||"منتج")} <small class="condition-label">${esc(p.condition||"جديد")}</small></h3><div class="specs">${esc(p.specs||p.description||"اسألنا عن التفاصيل")}</div><div class="prices"><span class="price">${money(p.price)}</span>${p.old_price&&Number(p.old_price)>Number(p.price)?`<span class="old-price">${money(p.old_price)}</span>`:""}</div><button class="add-cart" type="button" data-add="${esc(p.id)}">أضف إلى السلة</button></div></article>`).join("");
 grid.querySelectorAll("[data-product]").forEach(card=>{card.addEventListener("click",e=>{if(e.target.closest("[data-add]"))return;showProduct(card.dataset.product);});card.addEventListener("keydown",e=>{if(e.key==="Enter")showProduct(card.dataset.product);});});
 grid.querySelectorAll("[data-add]").forEach(b=>b.onclick=e=>{e.stopPropagation();addCart(b.dataset.add);});
 if(!list.length){status.hidden=false;status.innerHTML=products.length?'لا توجد منتجات في هذا القسم حاليًا.':`<div class="empty-offer"><b>عرض مميز من الجباس استور</b><h3>iPhone 18 Pro Max — برجاندي</h3><strong>99,999 جنيه</strong><p>لا توجد منتجات مضافة حاليًا. تواصل معنا للتأكد من التوافر.</p><a href="${wa("السلام عليكم، عايز أستفسر عن عرض الآيفون.")}" target="_blank">اسأل عن العرض على واتساب</a></div>`;}else status.hidden=true;
}
function showProduct(id){
 const p=products.find(x=>String(x.id)===String(id));if(!p)return;
 const page=$("#product-page");page.hidden=false;
 page.innerHTML=`<button class="btn outline back-to-shop" style="color:#061629;border-color:#dce2eb" type="button">← الرجوع للمتجر</button><div class="product-page-inner"><div class="product-page-image">${p.image?`<img src="${esc(p.image)}" alt="${esc(p.name)}">`:'<div class="placeholder">الصورة غير متاحة</div>'}</div><div class="product-page-info"><span class="eyebrow">${esc(p.category||"منتجات الجباس استور")}</span><h1>${esc(p.name||"منتج")}</h1><span class="condition-label">${esc(p.condition||"جديد")}</span><strong class="product-page-price">${money(p.price)}</strong>${p.old_price&&Number(p.old_price)>Number(p.price)?`<del>${money(p.old_price)}</del>`:""}<p>${esc(p.description||p.specs||"تواصل معنا لمعرفة تفاصيل المنتج.")}</p><p>${Number(p.quantity)>0?"متاح حاليًا":"يرجى تأكيد التوافر قبل الطلب"}</p><div class="qty-row"><label for="product-qty">الكمية</label><input id="product-qty" type="number" min="1" max="${Math.max(1,Number(p.quantity)||99)}" value="1"></div><button class="add-cart" id="page-add-cart" type="button">أضف إلى السلة</button></div></div>`;
 page.querySelector(".back-to-shop").onclick=()=>{page.hidden=true;document.querySelector("#products").scrollIntoView({behavior:"smooth"});};
 $("#page-add-cart").onclick=()=>addCart(id,Number($("#product-qty").value)||1);
 page.scrollIntoView({behavior:"smooth"});history.replaceState(null,"","#product-"+encodeURIComponent(id));
}
function saveCart(){localStorage.setItem("algabas_cart",JSON.stringify(cart));renderCart();}
function addCart(id,qty=1){const p=products.find(x=>String(x.id)===String(id));if(!p)return;qty=Math.max(1,Math.floor(Number(qty)||1));if(Number(p.quantity)>0)qty=Math.min(qty,Number(p.quantity));const old=cart.find(x=>String(x.id)===String(id));if(old){old.qty+=qty;if(Number(p.quantity)>0)old.qty=Math.min(old.qty,Number(p.quantity));}else cart.push({id:p.id,qty});saveCart();openCart();}
function renderCart(){
 const totalCount=cart.reduce((n,x)=>n+x.qty,0);$("#cart-count").textContent=totalCount.toLocaleString("ar-EG");
 const items=$("#cart-items");let total=0;
 if(!cart.length){items.innerHTML='<div class="cart-empty"><div style="font-size:42px">🛒</div><strong>لسه ما اخترتش أي منتج</strong><p>اختار المنتج اللي يعجبك وهيظهر هنا في السلة.</p></div>';$("#cart-total").textContent="";$("#checkout").disabled=true;return;}
 items.innerHTML=cart.map(c=>{const p=products.find(x=>String(x.id)===String(c.id));if(!p)return "";total+=Number(p.price||0)*c.qty;return `<div class="cart-item">${p.image?`<img src="${esc(p.image)}" alt="">`:"📱"}<div><b>${esc(p.name)}</b><div>${money(p.price)} × ${c.qty}</div><div class="qty-row"><button data-dec="${esc(c.id)}" type="button">−</button><span>${c.qty}</span><button data-inc="${esc(c.id)}" type="button">+</button></div></div><button type="button" data-remove="${esc(c.id)}">حذف</button></div>`;}).join("");
 $("#cart-total").textContent=`الإجمالي: ${money(total)}`;$("#checkout").disabled=false;
 items.querySelectorAll("[data-dec]").forEach(b=>b.onclick=()=>changeQty(b.dataset.dec,-1));items.querySelectorAll("[data-inc]").forEach(b=>b.onclick=()=>changeQty(b.dataset.inc,1));items.querySelectorAll("[data-remove]").forEach(b=>b.onclick=()=>{cart=cart.filter(x=>String(x.id)!==b.dataset.remove);saveCart();});
}
function changeQty(id,delta){const item=cart.find(x=>String(x.id)===String(id));if(!item)return;const p=products.find(x=>String(x.id)===String(id));item.qty+=delta;if(p&&Number(p.quantity)>0)item.qty=Math.min(item.qty,Number(p.quantity));if(item.qty<1)cart=cart.filter(x=>String(x.id)!==String(id));saveCart();}
function openCart(){ $("#cart-panel").hidden=false;$("#cart-shade").hidden=false;renderCart();}
function closeCart(){$("#cart-panel").hidden=true;$("#cart-shade").hidden=true;}
$("#cart-open").onclick=openCart;$("#cart-close").onclick=closeCart;$("#cart-shade").onclick=closeCart;
$("#checkout").onclick=()=>{if(!cart.length){renderCart();return;}let lines=["السلام عليكم، عايز أطلب المنتجات دي من الجباس استور:"];let total=0;cart.forEach(c=>{const p=products.find(x=>String(x.id)===String(c.id));if(p){lines.push(`- ${p.name} | الكمية: ${c.qty} | السعر: ${p.price} جنيه`);total+=Number(p.price||0)*c.qty;}});lines.push(`الإجمالي: ${total} جنيه`);window.open(wa(lines.join("\n")),"_blank","noopener");};
document.querySelectorAll(".cat").forEach(b=>b.addEventListener("click",()=>{document.querySelectorAll(".cat").forEach(x=>x.classList.remove("active"));b.classList.add("active");selectedCategory=b.dataset.category;const key=Object.keys(sectionToCategory).find(k=>sectionToCategory[k]===selectedCategory);const url=new URL(location.href);if(key)url.searchParams.set("section",key);else url.searchParams.delete("section");history.replaceState(null,"",url.pathname+url.search+"#products");render();}));
document.querySelectorAll("[data-jump-category]").forEach(a=>a.addEventListener("click",e=>{e.preventDefault();selectedCategory=a.dataset.jumpCategory;document.querySelectorAll(".cat").forEach(b=>{b.classList.toggle("active",b.dataset.category===selectedCategory);});$("#search").value="";const key=Object.keys(sectionToCategory).find(k=>sectionToCategory[k]===selectedCategory);const url=new URL(location.href);if(key)url.searchParams.set("section",key);history.pushState(null,"",url.pathname+url.search+"#products");render();$("#products").scrollIntoView({behavior:"smooth"});}));
window.addEventListener("popstate",()=>{const key=new URLSearchParams(location.search).get("section");selectedCategory=sectionToCategory[key]||"الكل";document.querySelectorAll(".cat").forEach(b=>b.classList.toggle("active",b.dataset.category===selectedCategory));render();});
$("#search").addEventListener("input",render);$("#sort").addEventListener("change",render);
async function init(){document.querySelectorAll(".cat").forEach(b=>b.classList.toggle("active",b.dataset.category===selectedCategory));if(!window.SUPABASE_URL||!window.SUPABASE_PUBLISHABLE_KEY){status.hidden=false;status.textContent="إعدادات الاتصال بقاعدة البيانات غير موجودة في config.js.";return;}if(!window.supabase?.createClient){status.hidden=false;status.textContent="تعذر تحميل مكتبة الاتصال. اتأكد من الإنترنت ثم أعد تحميل الصفحة.";return;}try{const client=window.supabase.createClient(window.SUPABASE_URL,window.SUPABASE_PUBLISHABLE_KEY);const {data,error}=await client.from("products").select("id,name,category,price,old_price,quantity,specs,condition,image,badge,description,created_at").order("created_at",{ascending:false});if(error)throw error;products=data||[];cart=cart.filter(c=>products.some(p=>String(p.id)===String(c.id)));saveCart();render();renderCart();const hash=location.hash.match(/^#product-(.+)$/);if(hash){const id=decodeURIComponent(hash[1]);if(products.some(p=>String(p.id)===id))showProduct(id);}}catch(err){status.hidden=false;status.textContent=`تعذر تحميل المنتجات من Supabase: ${err.message||"خطأ غير معروف"}`;}}
init();
})();
 
