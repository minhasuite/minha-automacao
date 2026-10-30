// Service worker da PWA (Lote 1): só push. Não guarda páginas em cache (o
// painel é ao vivo). Mensagem do servidor = Push::Message#to_h, ou
// {type: "clear", tag} para apagar o aviso daquela tag.

self.addEventListener("install", () => self.skipWaiting())
self.addEventListener("activate", (event) => event.waitUntil(self.clients.claim()))

self.addEventListener("push", (event) => {
  let msg = {}
  try { msg = event.data ? event.data.json() : {} } catch (_) { msg = { title: "Minha Automação", body: event.data?.text() || "" } }

  if (msg.type === "clear") {
    event.waitUntil(self.registration.getNotifications({ tag: msg.tag }).then((list) => list.forEach((n) => n.close())))
    return
  }

  const options = {
    body: msg.body || "",
    icon: msg.icon || "/icon-192.png",
    badge: msg.badge || "/badge-96.png",
    image: msg.image || undefined,
    tag: msg.tag || undefined,
    renotify: !!(msg.tag && msg.renotify),
    requireInteraction: !!msg.requireInteraction,
    actions: (msg.actions || []).slice(0, 3),
    data: msg.data || {}
  }
  event.waitUntil(self.registration.showNotification(msg.title || "Minha Automação", options))
})

self.addEventListener("notificationclick", (event) => {
  const n = event.notification
  const data = n.data || {}
  n.close()
  const answer = event.action && data.token
    ? fetch("/push/resposta", { method: "POST", headers: { "Content-Type": "application/json" }, credentials: "omit",
                                body: JSON.stringify({ token: data.token, action_id: event.action }) }).catch(() => null)
    : Promise.resolve()
  // Botão respondido não abre nada; tocar no corpo abre o link do aviso.
  const open = event.action ? Promise.resolve() : focusOrOpen(data.url || "/notificacoes")
  event.waitUntil(Promise.all([answer, open]))
})

function focusOrOpen(url) {
  const target = new URL(url, self.location.origin).href
  return self.clients.matchAll({ type: "window", includeUncontrolled: true }).then((list) => {
    const same = list.find((c) => new URL(c.url).origin === self.location.origin)
    if (same && new URL(target).origin === self.location.origin) return same.navigate(target).then((c) => (c || same).focus())
    return self.clients.openWindow(target)
  })
}
