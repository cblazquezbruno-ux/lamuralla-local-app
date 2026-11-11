// La Muralla Local · service worker: avisos al móvil y arranque rápido (los datos siempre se piden en directo)
const C='lml-v3';
self.addEventListener('install',e=>{e.waitUntil(caches.open(C).then(c=>c.addAll(['./','index.html','manifest.webmanifest','icon-192.png'])).then(()=>self.skipWaiting()))});
self.addEventListener('activate',e=>{e.waitUntil(caches.keys().then(ks=>Promise.all(ks.filter(k=>k!==C).map(k=>caches.delete(k)))).then(()=>self.clients.claim()))});
self.addEventListener('fetch',e=>{const u=new URL(e.request.url);if(e.request.method!=='GET'||u.origin!==location.origin)return;
  e.respondWith(fetch(e.request).then(r=>{const cp=r.clone();caches.open(C).then(c=>c.put(e.request,cp));return r}).catch(()=>caches.match(e.request).then(r=>r||caches.match('index.html'))))});
self.addEventListener('push',e=>{let d={};try{d=e.data.json()}catch(_){d={title:'La Muralla',body:e.data&&e.data.text()}}
  e.waitUntil(self.registration.showNotification(d.title||'La Muralla',{body:d.body||'',icon:'icon-192.png',badge:'icon-192.png',tag:d.url||'lml',renotify:true,data:{url:d.url||'./'}}))});
self.addEventListener('notificationclick',e=>{e.notification.close();const url=new URL((e.notification.data&&e.notification.data.url)||'./',self.registration.scope).href;
  e.waitUntil(self.clients.matchAll({type:'window',includeUncontrolled:true}).then(cs=>{for(const c of cs){if(c.url.startsWith(self.registration.scope)){c.navigate(url);return c.focus()}}return self.clients.openWindow(url)}))});
