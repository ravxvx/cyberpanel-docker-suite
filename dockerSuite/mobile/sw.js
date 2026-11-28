// Docker Suite phone app - service worker.
// Keeps the app shell (page, icons) for offline start; live data is always fetched from the server.
const CACHE = 'ds-m-v1';
const SHELL = ['/dockerSuite/m/', '/dockerSuite/m/icon-192.png', '/dockerSuite/m/manifest.webmanifest'];
self.addEventListener('install', e => { e.waitUntil(caches.open(CACHE).then(c => c.addAll(SHELL)).catch(() => {})); self.skipWaiting(); });
self.addEventListener('activate', e => { e.waitUntil(caches.keys().then(k => Promise.all(k.filter(x => x !== CACHE).map(x => caches.delete(x))))); self.clients.claim(); });
self.addEventListener('fetch', e => {
  const r = e.request;
  if (r.method !== 'GET' || !r.url.includes('/dockerSuite/m/')) { return; }
  // network first, so a fresh login/session always wins; cache only as an offline fallback
  e.respondWith(fetch(r).then(res => { if (res.ok && res.type === 'basic' && !res.redirected) { const cp = res.clone(); caches.open(CACHE).then(c => c.put(r, cp)); } return res; })
    .catch(() => caches.match(r)));
});
