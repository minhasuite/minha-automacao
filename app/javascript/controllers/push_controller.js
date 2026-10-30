import { Controller } from "@hotwired/stimulus"

// Meus aparelhos: inscreve este navegador no Web Push (chave VAPID pública do
// servidor) e manda a inscrição para o Rails. Só funciona em https (ou
// localhost) e, no iPhone, com a PWA aberta pela tela inicial.
export default class extends Controller {
  static targets = ["status", "button", "name"]
  static values = { key: String, url: String }

  async connect() {
    if (!window.isSecureContext) return this.state("O push exige https: abra pelo acesso externo para inscrever este aparelho.")
    if (!("serviceWorker" in navigator) || !("PushManager" in window)) {
      return this.state("Este navegador não recebe push. No iPhone, adicione à Tela de Início e abra pelo ícone.")
    }
    if (!this.keyValue) return this.state("O push está desligado no servidor (faltam as chaves VAPID).")
    if (Notification.permission === "denied") return this.state("Notificações bloqueadas nas configurações do navegador.")
    const reg = await navigator.serviceWorker.ready
    const sub = await reg.pushManager.getSubscription()
    this.state(sub ? "Este aparelho já recebe os avisos. Inscrever de novo atualiza o nome." : "Este aparelho ainda não recebe os avisos.", true)
  }

  async subscribe() {
    this.buttonTarget.disabled = true
    try {
      if ((await Notification.requestPermission()) !== "granted") return this.state("Permissão de notificação negada.", true)
      const reg = await navigator.serviceWorker.ready
      const sub = (await reg.pushManager.getSubscription()) ||
        (await reg.pushManager.subscribe({ userVisibleOnly: true, applicationServerKey: this.decode(this.keyValue) }))
      const json = sub.toJSON()
      const res = await fetch(this.urlValue, {
        method: "POST",
        headers: { "Content-Type": "application/json", Accept: "application/json", "X-CSRF-Token": document.querySelector("meta[name=csrf-token]")?.content },
        body: JSON.stringify({ endpoint: json.endpoint, keys: json.keys, name: this.nameTarget.value })
      })
      if (!res.ok) return this.state("O servidor não guardou a inscrição. Tente de novo.", true)
      Turbo.visit(location.href, { action: "replace" })
    } catch (e) {
      this.state(`Não foi possível inscrever: ${e.message}`, true)
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
