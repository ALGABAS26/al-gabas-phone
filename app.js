(() => {
const SHOP_PHONE="201110103452", $=s=>document.querySelector(s);
const grid=$("#product-grid"), status=$("#status"), count=$("#product-count");
let products=[], selectedCategory="الكل", productReturnScroll=0;
let cart=[];
try { const saved=JSON.parse(localStorage.getItem("algabas_cart")||"[]"); cart=Array.isArray(saved)?saved.filter(x=>x&&x.id!==undefined&&Number(x.qty)>0).map(x=>({id:x.id,qty:Math.floor(Number(x.qty))})):[]; } catch { cart=[]; }
$("#year").textContent=new Date().getFullYear();
function esc(v=""){return String(v).replace(/[&<>"']/g,c=>({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;","'":"&#39;"}[c]));}
function imageUrls(value){if(!value)return [];if(Array.isArray(value))return value.filter(Boolean);if(typeof value!=="string")return [];const raw=value.trim();if(!raw)return [];try{const parsed=JSON.parse(raw);if(Array.isArray(parsed))return parsed.filter(x=>typeof x==="string"&&x);}catch{}return [raw];}
function money(v){const n=Number(v);return Number.isFinite(n)?`L.E ${n.toLocaleString("en-US")}`:"السعر عند الاستفسار";}
function discountInfo(p){const old=Number(p.old_price),now=Number(p.price);if(!(old>now&&now>=0))return null;return {amount:old-now,percent:Math.round((old-now)/old*100)};}
function productSpecs(p){const raw=String(p.specs||p.description||"");const m=raw.match(/\[\[BATTERY:(\d{1,3})\]\]/i);return {battery:m?m[1]:"",text:raw.replace(/\s*\[\[BATTERY:\d{1,3}\]\]\s*/ig," ").trim()};}
function wa(text){return `https://wa.me/${SHOP_PHONE}?text=${encodeURIComponent(text)}`;}
document.querySelectorAll("[data-whatsapp]").forEach(a=>{a.href=wa("السلام عليكم، عايز أستفسر عن منتجات الجباس استور.");a.target="_blank";a.rel="noopener noreferrer";});
const hero=document.querySelector('.hero-slider');let heroSlide=0;
const heroData=[{image:'home-hero.jpg',name:'iPhone 18 Pro Max',message:'السلام عليكم، عايز أستفسر عن جهاز iPhone 18 Pro Max الموجود في إعلان الجباس استور.'},{image:'home-hero-s26.jpg',name:'Samsung Galaxy S26 Ultra',message:'السلام عليكم، عايز أستفسر عن جهاز Samsung Galaxy S26 Ultra الموجود في إعلان الجباس استور.'}];
function setHeroSlide(n){heroSlide=(n+heroData.length)%heroData.length;const d=heroData[heroSlide];hero.style.backgroundImage=`url('${d.image}')`;const buy=document.querySelector('#hero-buy');buy.href=wa(d.message);buy.target='_blank';buy.rel='noopener noreferrer';document.querySelectorAll('.hero-dots button').forEach((b,i)=>b.classList.toggle('active',i===heroSlide));}
setHeroSlide(0);document.querySelector('.hero-prev').addEventListener('click',()=>setHeroSlide(heroSlide-1));document.querySelector('.hero-next').addEventListener('click',()=>setHeroSlide(heroSlide+1));document.querySelectorAll('.hero-dots button').forEach(b=>b.addEventListener('click',()=>setHeroSlide(Number(b.dataset.slide))));

function categoryMatch(p){
 const hay=[p.name,p.category,p.description,p.specs,p.condition,p.brand,p.model].filter(Boolean).join(" ").toLocaleLowerCase("ar");
 const cat=String(p.category||"").toLocaleLowerCase("ar");
 const isAccessory=/إكسسوار|اكسسوار|accessor|جراب|شاحن|سماعة|ساعة ذكية|كابل/i.test(hay);
 const isIphone=/iphone|آيفون|ايفون|apple|ابل|أبل/i.test(hay);
 const isAndroid=/android|أندرويد|اندرويد|samsung|سامسونج|xiaomi|شاومي|redmi|ريدمي|oppo|أوبو|vivo|فيفو|realme|ريلمي|huawei|هواوي|honor|هونر|infinix|انفنكس|tecno|تكنو|oneplus/i.test(hay);
 if(selectedCategory==="آيفون") return isIphone && !isAccessory;
 if(selectedCategory==="أندرويد") return isAndroid && !isIphone && !isAccessory;
 if(selectedCategory==="موبايلات جديدة") return !isAccessory && ["جديد","مجدد من أبل"].includes(String(p.condition||"").trim());
 if(selectedCategory==="إكسسوارات") return isAccessory;
 if(selectedCategory==="عروض") return !!discountInfo(p);
 if(selectedCategory==="الصيانة") return false;
 return true;
}
function render(){
 const q=$("#search").value.trim().toLocaleLowerCase("ar");
 let list=products.filter(p=>categoryMatch(p)&&[p.name,p.category,p.description,p.specs,p.condition].filter(Boolean).join(" ").toLocaleLowerCase("ar").includes(q));
 if(selectedCategory==="عروض") { const discounted=products.filter(p=>discountInfo(p)); const over25=discounted.filter(p=>discountInfo(p).percent>25); const chosen=over25.length?over25:discounted.sort((a,b)=>discountInfo(b).percent-discountInfo(a).percent).slice(0,3); list=chosen.filter(p=>[p.name,p.category,p.description,p.specs,p.condition].filter(Boolean).join(" ").toLocaleLowerCase("ar").includes(q)); }
 if(selectedCategory==="الصيانة"){count.textContent="خدمة الصيانة";grid.innerHTML="";status.hidden=false;status.innerHTML='<div class="maintenance-notice"><strong>⚒ الصيانة متوفرة داخل المحل</strong><p>هذه الخدمة متوفرة داخل المحل، وسنعمل على إضافتها إلى المتجر الإلكتروني قريبًا.</p></div>';return;}
 const sort=$("#sort").value;if(sort==="price-asc")list.sort((a,b)=>Number(a.price)-Number(b.price));if(sort==="price-desc")list.sort((a,b)=>Number(b.price)-Number(a.price));if(sort==="newest")list.sort((a,b)=>new Date(b.created_at||0)-new Date(a.created_at||0));
 count.textContent=`${list.length.toLocaleString("ar-EG")} منتج`;
 grid.innerHTML=list.map((p,i)=>{const d=discountInfo(p),sp=productSpecs(p);return `<article class="product-card" tabindex="0" role="button" data-product="${esc(p.id)}"><div class="product-image">${imageUrls(p.image).length?`<img src="${esc(imageUrls(p.image)[0])}" alt="${esc(p.name)}" loading="lazy">`:'<span class="placeholder">الصورة غير متاحة</span>'}${d?`<span class="saving-badge">وفر ${Math.round(d.amount).toLocaleString("en-US")} جنيه</span>`:""}</div><div class="product-info"><span class="product-category">${esc(p.category||"منتجات الجباس استور")}</span><h3>${esc(p.name||"منتج")} </h3>${sp.battery?`<div class="battery-label">صحة البطارية: ${esc(sp.battery)}%</div>`:""}<div class="specs">${esc(sp.text||"اسألنا عن التفاصيل")}</div><div class="prices"><span class="price">${money(p.price)}</span>${d?`<span class="discount-percent">-${d.percent}%</span><span class="old-price">${money(p.old_price)}</span>`:""}</div><button class="add-cart" type="button" data-add="${esc(p.id)}">أضف إلى السلة</button></div></article>`}).join("");
 grid.querySelectorAll("[data-product]").forEach(card=>{card.addEventListener("click",e=>{if(e.target.closest("[data-add]"))return;showProduct(card.dataset.product);});card.addEventListener("keydown",e=>{if(e.key==="Enter")showProduct(card.dataset.product);});});
 grid.querySelectorAll("[data-add]").forEach(b=>b.onclick=e=>{e.stopPropagation();addCart(b.dataset.add);});
 if(!list.length){status.hidden=false;status.innerHTML=products.length?'لا توجد منتجات في هذا القسم حاليًا.':`<div class="empty-offer"><b>عرض مميز من الجباس استور</b><h3>iPhone 18 Pro Max — برجاندي</h3><strong>99,999 جنيه</strong><p>لا توجد منتجات مضافة حاليًا. تواصل معنا للتأكد من التوافر.</p><a href="${wa("السلام عليكم، عايز أستفسر عن عرض الآيفون.")}" target="_blank">اسأل عن العرض على واتساب</a></div>`;}else status.hidden=true;
}
function showProduct(id){
 const p=products.find(x=>String(x.id)===String(id));if(!p)return;
 const page=$("#product-page");productReturnScroll=window.scrollY;page.hidden=false;document.body.classList.add("product-open");page.scrollTop=0;
 const pics=imageUrls(p.image),d=discountInfo(p),sp=productSpecs(p);page.innerHTML=`<button class="btn outline back-to-shop" style="color:#061629;border-color:#dce2eb" type="button">← الرجوع للمتجر</button><div class="product-page-inner"><div class="product-gallery"><div class="product-page-image">${pics.length?`<img id="product-main-image" src="${esc(pics[0])}" alt="${esc(p.name)}">`:'<div class="placeholder">الصورة غير متاحة</div>'}</div>${pics.length>1?`<div class="product-thumbnails">${pics.map((src,i)=>`<button type="button" class="product-thumb ${i===0?"active":""}" data-image-index="${i}" aria-label="الصورة ${i+1}"><img src="${esc(src)}" alt=""></button>`).join("")}</div>`:""}</div><div class="product-page-info"><span class="eyebrow">${esc(p.category||"منتجات الجباس استور")}</span><h1>${esc(p.name||"منتج")}</h1><div class="detail-pricing"><strong class="product-page-price">${money(p.price)}</strong>${d?`<span class="discount-percent">-${d.percent}%</span><del class="detail-old-price">${money(p.old_price)}</del><span class="saving-detail">وفر ${Math.round(d.amount).toLocaleString("en-US")} جنيه</span>`:""}</div>${sp.battery?`<div class="battery-label">صحة البطارية: ${esc(sp.battery)}%</div>`:""}<p>${esc(p.description||sp.text||"تواصل معنا لمعرفة تفاصيل المنتج.")}</p><p>${Number(p.quantity)>0?"متاح حاليًا":"يرجى تأكيد التوافر قبل الطلب"}</p><div class="qty-row"><label for="product-qty">الكمية</label><input id="product-qty" type="number" min="1" max="${Math.max(1,Number(p.quantity)||99)}" value="1"></div><button class="add-cart" id="page-add-cart" type="button">أضف إلى السلة</button></div></div>`;
 page.querySelectorAll("[data-image-index]").forEach(btn=>btn.onclick=()=>{const idx=Number(btn.dataset.imageIndex);$("#product-main-image").src=pics[idx];page.querySelectorAll(".product-thumb").forEach(t=>t.classList.toggle("active",t===btn));});page.querySelector(".back-to-shop").onclick=()=>{page.hidden=true;document.body.classList.remove("product-open");history.replaceState(null,"",location.pathname+location.search);window.scrollTo({top:productReturnScroll,behavior:"smooth"});};
 $("#page-add-cart").onclick=()=>addCart(id,Number($("#product-qty").value)||1);
 page.scrollTop=0;const productHash="#product-"+encodeURIComponent(id);if(location.hash!==productHash)history.pushState({productId:id},"",productHash);
}
function saveCart(){localStorage.setItem("algabas_cart",JSON.stringify(cart));renderCart();}
function addCart(id,qty=1){const p=products.find(x=>String(x.id)===String(id));if(!p)return;qty=Math.max(1,Math.floor(Number(qty)||1));if(Number(p.quantity)>0)qty=Math.min(qty,Number(p.quantity));const old=cart.find(x=>String(x.id)===String(id));if(old){old.qty+=qty;if(Number(p.quantity)>0)old.qty=Math.min(old.qty,Number(p.quantity));}else cart.push({id:p.id,qty});saveCart();openCart();}
function renderCart(){
 const totalCount=cart.reduce((n,x)=>n+x.qty,0);$("#cart-count").textContent=totalCount.toLocaleString("ar-EG");
 const items=$("#cart-items");let total=0;
 if(!cart.length){items.innerHTML='<div class="cart-empty"><div style="font-size:42px">🛒</div><strong>لسه ما اخترتش أي منتج</strong><p>اختار المنتج اللي يعجبك وهيظهر هنا في السلة.</p></div>';$("#cart-total").textContent="";$("#checkout").disabled=true;return;}
 items.innerHTML=cart.map(c=>{const p=products.find(x=>String(x.id)===String(c.id));if(!p)return "";total+=Number(p.price||0)*c.qty;return `<div class="cart-item">${imageUrls(p.image).length?`<img src="${esc(imageUrls(p.image)[0])}" alt="">`:"📱"}<div><b>${esc(p.name)}</b><div>${money(p.price)} × ${c.qty}</div><div class="qty-row"><button data-dec="${esc(c.id)}" type="button">−</button><span>${c.qty}</span><button data-inc="${esc(c.id)}" type="button">+</button></div></div><button type="button" data-remove="${esc(c.id)}">حذف</button></div>`;}).join("");
 $("#cart-total").textContent=`الإجمالي: ${money(total)}`;$("#checkout").disabled=false;
 items.querySelectorAll("[data-dec]").forEach(b=>b.onclick=()=>changeQty(b.dataset.dec,-1));items.querySelectorAll("[data-inc]").forEach(b=>b.onclick=()=>changeQty(b.dataset.inc,1));items.querySelectorAll("[data-remove]").forEach(b=>b.onclick=()=>{cart=cart.filter(x=>String(x.id)!==b.dataset.remove);saveCart();});
}
function changeQty(id,delta){const item=cart.find(x=>String(x.id)===String(id));if(!item)return;const p=products.find(x=>String(x.id)===String(id));item.qty+=delta;if(p&&Number(p.quantity)>0)item.qty=Math.min(item.qty,Number(p.quantity));if(item.qty<1)cart=cart.filter(x=>String(x.id)!==String(id));saveCart();}
function openCart(){ $("#cart-panel").hidden=false;$("#cart-shade").hidden=false;renderCart();}
function closeCart(){$("#cart-panel").hidden=true;$("#cart-shade").hidden=true;}
$("#cart-open").onclick=openCart;$("#cart-close").onclick=closeCart;$("#cart-shade").onclick=closeCart;
$("#checkout").onclick=()=>{if(!cart.length){renderCart();return;}let lines=["السلام عليكم، عايز أطلب المنتجات دي من الجباس استور:"];let total=0;cart.forEach(c=>{const p=products.find(x=>String(x.id)===String(c.id));if(p){lines.push(`- ${p.name} | الكمية: ${c.qty} | السعر: ${p.price} جنيه`);total+=Number(p.price||0)*c.qty;}});lines.push(`الإجمالي: ${total} جنيه`);window.open(wa(lines.join("\n")),"_blank","noopener");};
document.querySelectorAll(".cat").forEach(b=>b.addEventListener("click",()=>{document.querySelectorAll(".cat").forEach(x=>x.classList.remove("active"));b.classList.add("active");selectedCategory=b.dataset.category;render();}));
document.querySelectorAll("[data-jump-category]").forEach(a=>a.addEventListener("click",e=>{e.preventDefault();selectedCategory=a.dataset.jumpCategory;document.querySelectorAll(".cat").forEach(b=>{b.classList.toggle("active",b.dataset.category===selectedCategory);});$("#search").value="";render();$("#products").scrollIntoView({behavior:"smooth"});}));
document.querySelectorAll("[data-maintenance]").forEach(a=>a.addEventListener("click",e=>{e.preventDefault();selectedCategory="الصيانة";document.querySelectorAll(".cat").forEach(b=>b.classList.remove("active"));$("#search").value="";render();$("#products").scrollIntoView({behavior:"smooth"});}));
$("#search").addEventListener("input",render);$("#sort").addEventListener("change",render);
window.addEventListener("popstate",()=>{const page=$("#product-page");if(page&&!page.hidden){page.hidden=true;document.body.classList.remove("product-open");window.scrollTo({top:productReturnScroll});}});
async function init(){if(!window.SUPABASE_URL||!window.SUPABASE_PUBLISHABLE_KEY){status.hidden=false;status.textContent="إعدادات الاتصال بقاعدة البيانات غير موجودة في config.js.";return;}if(!window.supabase?.createClient){status.hidden=false;status.textContent="تعذر تحميل مكتبة الاتصال. اتأكد من الإنترنت ثم أعد تحميل الصفحة.";return;}try{const client=window.supabase.createClient(window.SUPABASE_URL,window.SUPABASE_PUBLISHABLE_KEY);const {data,error}=await client.from("products").select("id,name,category,price,old_price,quantity,specs,condition,image,badge,description,created_at").order("created_at",{ascending:false});if(error)throw error;products=data||[];cart=cart.filter(c=>products.some(p=>String(p.id)===String(c.id)));saveCart();render();renderCart();const hash=location.hash.match(/^#product-(.+)$/);if(hash){const id=decodeURIComponent(hash[1]);if(products.some(p=>String(p.id)===id))showProduct(id);}}catch(err){status.hidden=false;status.textContent=`تعذر تحميل المنتجات من Supabase: ${err.message||"خطأ غير معروف"}`;}}
init();
})();
 
