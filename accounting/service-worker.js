const CACHE_NAME = "algabas-store-shell-v7";
const SHELL = ["./", "./index.html", "./style.css", "./app.js", "./manifest.webmanifest", "./store-icon.svg", "./logo.png"];
self.addEventListener("install", event => {
  event.waitUntil(caches.open(CACHE_NAME).then(cache => cache.addAll(SHELL)).then(() => self.skipWaiting()));
});
self.addEventListener("activate", event => {
  event.waitUntil(caches.keys().then(keys => Promise.all(keys.filter(key => key !== CACHE_NAME).map(key => caches.delete(key)))).then(() => self.clients.claim()));
});
self.addEventListener("fetch", event => {
  const request = event.request;
  const url = new URL(request.url);
  if (request.method !== "GET" || url.origin !== self.location.origin) return;
  if (url.pathname.includes("/rest/") || url.pathname.includes("/auth/")) return;
  event.respondWith(fetch(request).then(response => {
    if (response.ok && (url.pathname.endsWith(".css") || url.pathname.endsWith(".js") || url.pathname.endsWith(".svg") || url.pathname.endsWith(".webmanifest"))) {
      const copy = response.clone();
      caches.open(CACHE_NAME).then(cache => cache.put(request, copy));
    }
    return response;
  }).catch(() => caches.match(request).then(cached => cached || caches.match("./index.html"))));
});