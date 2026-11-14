import { Controller } from "@hotwired/stimulus"
import { standalone, ios, iosSafari, installPrompt } from "controllers/pwa/platform"

// Instalar o app (pwa-ios, docs/pwa.md). O iPhone não tem beforeinstallprompt: lá vale o passo a passo
// (Compartilhar → Adicionar à Tela de Início); no Android/computador, o botão chama o pedido do navegador.
// mode "settings" (Configurações → Aparência #instalar): mostra o que vale para este aparelho.
// mode "notice" (Início): o aviso discreto só no Safari do iPhone fora do app instalado, até dispensar
// (localStorage "ma-install-notice" = "off", só deste aparelho).
const KEY = "ma-install-notice"

export default class extends Controller {
  static targets = ["button", "ios", "other", "installed", "https"]
  static values = { mode: { type: String, default: "settings" } }

  connect() {
    this.onPrompt = () => this.render()
    window.addEventListener("ma:installable", this.onPrompt)
    window.addEventListener("appinstalled", this.onPrompt)
    this.render()
  }

  disconnect() {
    window.removeEventListener("ma:installable", this.onPrompt)
    window.removeEventListener("appinstalled", this.onPrompt)
  }

  render() {
    if (this.modeValue === "notice") {
      let off = false
      try { off = localStorage.getItem(KEY) === "off" } catch (_) { /* sem localStorage: mostra */ }
      this.element.hidden = !iosSafari() || standalone() || off
      return
    }
    const inApp = standalone()
    const prompt = installPrompt()
    this.toggle("installed", inApp)
    this.toggle("ios", !inApp && ios())
    this.toggle("other", !inApp && !ios())
    this.toggle("button", !inApp && !!prompt)
    this.toggle("https", !inApp && !window.isSecureContext)
  }

  toggle(name, on) {
    this[`${name}Targets`].forEach((el) => { el.hidden = !on })
  }

  async install() {
    const prompt = installPrompt()
    if (!prompt) return
    window.maInstallPrompt = null
    prompt.prompt()
    await prompt.userChoice.catch(() => null)
    this.render()
  }

  // Ss::NoticeCardComponent dispensável: o X dispara "ss-notice:dismiss".
  dismiss() {
    try { localStorage.setItem(KEY, "off") } catch (_) { /* segue */ }
  }
}
