import { Controller } from "@hotwired/stimulus"
import { ios, standalone } from "controllers/pwa/platform"

// Meus aparelhos: inscreve este navegador no Web Push (chave VAPID pública do
// servidor) e manda a inscrição para o Rails. Só funciona em https (ou
// localhost) e, no iPhone, com a PWA aberta pela tela inicial.
export default class extends Controller {
  static targets = ["status", "button", "name"]
  // Textos no idioma da tela (`data-push-texts-value`, push.js em config/locales/home.*.yml).
  static values = { key: String, url: String, texts: Object }

  async connect() {
    const t = this.textsValue
    if (!window.isSecureContext) return this.state(t.https)
    // pwa-ios: no iPhone o push só existe no app da Tela de Início (iOS 16.4+); no Safari comum explica
    // como instalar em vez de dizer só "não recebe".
    if (ios() && !standalone()) return this.state(t.ios_install)
    if (ios() && !("PushManager" in window)) return this.state(t.ios_old)
    if (!("serviceWorker" in navigator) || !("PushManager" in window)) {
      return this.state(t.unsupported)
    }
    if (!this.keyValue) return this.state(t.no_keys)
    if (Notification.permission === "denied") return this.state(t.blocked)
    const reg = await navigator.serviceWorker.ready
    const sub = await reg.pushManager.getSubscription()
    this.state(sub ? t.subscribed : t.not_subscribed, true)
  }

  async subscribe() {
    this.buttonTarget.disabled = true
    try {
      if ((await Notification.requestPermission()) !== "granted") return this.state(this.textsValue.denied, true)
      const reg = await navigator.serviceWorker.ready
      const sub = (await reg.pushManager.getSubscription()) ||
        (await reg.pushManager.subscribe({ userVisibleOnly: true, applicationServerKey: this.decode(this.keyValue) }))
      const json = sub.toJSON()
      const res = await fetch(this.urlValue, {
        method: "POST",
        headers: { "Content-Type": "application/json", Accept: "application/json", "X-CSRF-Token": document.querySelector("meta[name=csrf-token]")?.content },
        body: JSON.stringify({ endpoint: json.endpoint, keys: json.keys, name: this.nameTarget.value })
      })
      if (!res.ok) return this.state(this.textsValue.not_saved, true)
      Turbo.visit(location.href, { action: "replace" })
    } catch (e) {
      this.state(`${this.textsValue.failed} ${e.message}`, true)
    }
  }

  state(text, enable = false) {
    this.statusTarget.textContent = text
    this.buttonTarget.disabled = !enable
  }

  decode(base64) {
    const b64 = (base64 + "=".repeat((4 - (base64.length % 4)) % 4)).replace(/-/g, "+").replace(/_/g, "/")
    return Uint8Array.from(atob(b64), (c) => c.charCodeAt(0))
  }
}
