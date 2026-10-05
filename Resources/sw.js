// Relay's service worker: shows Web Push notifications and opens the right card when one is tapped.
// iOS revokes a subscription whose pushes don't show anything, so every push shows a notification.
'use strict';

self.addEventListener('install', () => self.skipWaiting());
self.addEventListener('activate', (event) => event.waitUntil(self.clients.claim()));

self.addEventListener('push', (event) => {
  let data = {};
  try { data = event.data ? event.data.json() : {}; } catch (e) { data = {}; }
  // A newer push for the same item replaces the older notification.
  const tag = data.itemId || (data.kind === 'fire' ? 'fire-' + data.sessionId : 'relay-' + (data.kind || 'note'));
  event.waitUntil(self.registration.showNotification(data.title || 'Relay', {
    body: data.body || 'An agent needs you',
    tag,
    renotify: true,
    icon: '/icon-192.png',
    badge: '/icon-192.png',
    data: { itemId: data.itemId || '', sessionId: data.sessionId || '', kind: data.kind || '' },
  }));
});

self.addEventListener('notificationclick', (event) => {
  event.notification.close();
  const d = event.notification.data || {};
  const hash = d.itemId ? '#item=' + encodeURIComponent(d.itemId)
    : d.sessionId ? '#session=' + encodeURIComponent(d.sessionId) : '';
  event.waitUntil((async () => {
    const windows = await self.clients.matchAll({ type: 'window', includeUncontrolled: true });
    for (const client of windows) {
      if (new URL(client.url).origin !== self.location.origin) continue;
      client.postMessage({ type: 'open', hash });
      return client.focus();
    }
    return self.clients.openWindow('/' + hash);
  })());
});
