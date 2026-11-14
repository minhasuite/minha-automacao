import { Controller } from "@hotwired/stimulus"
import { ios, standalone } from "controllers/pwa/platform"

// Botão do Google (Google Identity Services): carrega o script do Google uma
// vez (vale também nas visitas do Turbo), desenha o botão no tema e no idioma
// da tela e, com o id_token, envia o formulário (com o CSRF do Rails). Sem
// rede para o Google, o bloco some e ficam os outros jeitos de entrar.
let gis
const loadGis = () => gis ||= new Promise((resolve, reject) => {
  const s = document.createElement("script")
  s.src = "https://accounts.google.com/gsi/client"
  s.async = true
  s.onload = resolve
  s.onerror = () => { gis = null; reject() }
  document.head.append(s)
})

export default class extends Controller {
  static values = { client: String, text: String, locale: String }
  static targets = ["form", "credential", "button", "standalone"]

  async connect() {
    // pwa-ios: no app da Tela de Início do iPhone o pop-up do Google pode não voltar; a nota aponta senha/passkey.
    if (this.hasStandaloneTarget) this.standaloneTarget.hidden = !(ios() && standalone())
    try { await loadGis() } catch { this.element.hidden = true; return }
    const root = document.documentElement
    const dark = root.dataset.theme === "dark" || (!root.dataset.theme && matchMedia("(prefers-color-scheme: dark)").matches)
    google.accounts.id.initialize({ client_id: this.clientValue, callback: (r) => this.signIn(r), ux_mode: "popup" })
    google.accounts.id.renderButton(this.buttonTarget, {
      type: "standard", size: "large", shape: "pill", text: this.textValue, locale: this.localeValue,
      theme: dark ? "filled_black" : "outline", logo_alignment: "center",
      width: Math.min(Math.max(this.buttonTarget.clientWidth, 200), 400)
    })
  }

  signIn({ credential }) {
    this.credentialTarget.value = credential
    this.formTarget.requestSubmit()
  }
}
