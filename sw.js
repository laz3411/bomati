const CACHE_NAME = 'roblox-radar-v5';
const ASSETS_TO_CACHE = [
  '/',
  '/index.html',
  '/image/realmap.png',
  '/manifest.json',
  '/icons/icon-192.png',
  '/icons/icon-512.png'
];

self.addEventListener('install', (event) => {
  event.waitUntil(
    caches.open(CACHE_NAME).then((cache) => {
      return cache.addAll(ASSETS_TO_CACHE).catch(err => {
        console.warn('일부 에셋 캐시 실패:', err);
      });
    })
  );
  self.skipWaiting();
});

self.addEventListener('activate', (event) => {
  event.waitUntil(
    caches.keys().then((keys) => {
      return Promise.all(
        keys.map((key) => {
          if (key !== CACHE_NAME) {
            return caches.delete(key);
          }
        })
      );
    })
  );
  self.clients.claim();
});

self.addEventListener('fetch', (event) => {
  const url = new URL(event.request.url);
  // Firebase API 및 외부 요청은 캐시하지 않고 통과
  if (url.origin !== location.origin || url.pathname.startsWith('/api/')) {
    return;
  }

  // 앱을 새로고침했을 때 정류장 수신 보완 코드가 이전 캐시로 되돌아가지 않게 합니다.
  if (url.pathname === '/' || url.pathname.endsWith('/index.html') || url.pathname.endsWith('/sw.js')) {
    event.respondWith(
      fetch(event.request).then((response) => {
        if (response && response.status === 200) {
          caches.open(CACHE_NAME).then((cache) => cache.put(event.request, response.clone()));
        }
        return response;
      }).catch(() => caches.match(event.request))
    );
    return;
  }

  event.respondWith(
    caches.match(event.request).then((cachedResponse) => {
      if (cachedResponse) {
        fetch(event.request).then((networkResponse) => {
          if (networkResponse && networkResponse.status === 200) {
            caches.open(CACHE_NAME).then((cache) => cache.put(event.request, networkResponse));
          }
        }).catch(() => {});
        return cachedResponse;
      }
      return fetch(event.request);
    })
  );
});
