// 汪喵回家 service worker v3.10.0
// 只快取網站外殼，讓離線時也能打開；資料（Supabase）一律走網路，不快取。
const CACHE = 'wanghome-v3.10.0';
// 不放 './index.html'：Cloudflare 會把 /index.html 轉址到 /，快取到轉址回應會讓離線開不起來
const SHELL = ['./', './manifest.webmanifest', './icon.svg', './icon-192.png', './icon-512.png', './duo.svg'];

self.addEventListener('install', e => {
  e.waitUntil(caches.open(CACHE).then(c => c.addAll(SHELL)).then(() => self.skipWaiting()));
});
self.addEventListener('activate', e => {
  e.waitUntil(caches.keys().then(ks => Promise.all(ks.filter(k => k !== CACHE).map(k => caches.delete(k)))).then(() => self.clients.claim()));
});
self.addEventListener('fetch', e => {
  const req = e.request;
  if (req.method !== 'GET') return;
  const url = new URL(req.url);
  if (url.origin !== location.origin) return;           // CDN、Supabase、地圖圖磚不處理
  const scope = new URL(self.registration.scope).pathname;
  const isShell = url.pathname === scope || url.pathname === scope + 'index.html';
  if (req.mode === 'navigate' && !isShell) return;      // 分享頁（/s/、/f/）等直接走網路，不覆蓋快取
  if (isShell) {
    // 網頁：先拿最新版，失敗才用快取；只快取正常回應
    e.respondWith(fetch(req).then(r => { if (r.ok && r.type === 'basic' && !r.redirected) { const c = r.clone(); caches.open(CACHE).then(x => x.put('./', c)); } return r; })
      .catch(() => caches.match('./')));
    return;
  }
  e.respondWith(caches.match(req).then(r => r || fetch(req)));
});
