// 汪喵回家 service worker v3.18.0
// 只快取網站外殼，讓離線時也能打開；資料（Supabase）一律走網路，不快取。
const CACHE = 'wanghome-v3.17.0';
// 不放 './index.html'：Cloudflare 會把 /index.html 轉址到 /，快取到轉址回應會讓離線開不起來
const SHELL = ['./', './manifest.webmanifest', './icon.svg', './icon-192.png', './icon-512.png', './duo.svg', './vendor/supabase-js-2.118.0.js'];
// 地圖程式（Leaflet）第一次用到地圖時才下載並快取；檔名含版本號，放在不隨發版清除的快取裡
const VENDOR = 'wanghome-vendor';

self.addEventListener('install', e => {
  e.waitUntil(caches.open(CACHE).then(c => c.addAll(SHELL)).then(() => self.skipWaiting()));
});
self.addEventListener('activate', e => {
  e.waitUntil(caches.keys().then(ks => Promise.all(ks.filter(k => k !== CACHE && k !== VENDOR).map(k => caches.delete(k)))).then(() => self.clients.claim()));
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
    e.respondWith(fetch(req).then(r => { if (r.ok && r.type === 'basic' && !r.redirected) { const c = r.clone(); caches.open(CACHE).then(x => x.put('./', c)); return r; }
      // 主機暫時出錯（5xx）：有快取就先用快取版本
      if (r.status >= 500) return caches.match('./').then(c => c || r); return r; })
      .catch(() => caches.match('./')));
    return;
  }
  if (url.pathname.startsWith(scope + 'vendor/')) {
    e.respondWith(caches.match(req).then(r => r || fetch(req).then(res => { if (res.ok && res.type === 'basic') { const c = res.clone(); caches.open(VENDOR).then(x => x.put(req, c)); } return res; })));
    return;
  }
  e.respondWith(caches.match(req).then(r => r || fetch(req)));
});
