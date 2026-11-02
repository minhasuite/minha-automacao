import { Controller } from "@hotwired/stimulus"

// Passkeys (ondaA2 A16): cadastrar (Segurança) e entrar (tela de entrada) por
// WebAuthn. Manda ao servidor a chave pública pronta (getPublicKey) e os dados
// do autenticador; o servidor confere desafio, origem e assinatura.
const b64 = (buf) => btoa(String.fromCharCode(...new Uint8Array(buf))).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "")
const unb64 = (s) => Uint8Array.from(atob(s.replace(/-/g, "+").replace(/_/g, "/").padEnd(Math.ceil(s.length / 4) * 4, "=")), (c) => c.charCodeAt(0))

export default class extends Controller {
  static values = { options: String, url: String }
  static targets = ["name", "error", "unsupported"]

  connect() {
    if (window.PublicKeyCredential) return
    this.element.querySelectorAll("form, [data-action*='passkey#login']").forEach((el) => { el.hidden = true })
    if (this.hasUnsupportedTarget) this.unsupportedTarget.hidden = false
  }

  async register(event) {
    event.preventDefault()
    try {
      const o = await this.options()
      o.user.id = unb64(o.user.id)
      o.excludeCredentials = o.excludeCredentials.map((c) => ({ ...c, id: unb64(c.id) }))
      const cred = await navigator.credentials.create({ publicKey: o })
      const r = cred.response
      await this.send({ id: b64(cred.rawId), clientDataJSON: b64(r.clientDataJSON), authenticatorData: b64(r.getAuthenticatorData()),
        publicKey: b64(r.getPublicKey()), name: this.hasNameTarget ? this.nameTarget.value : "" })
    } catch (e) { this.fail(e) }
  }

  async login(event) {
    event.preventDefault()
    try {
      const cred = await navigator.credentials.get({ publicKey: await this.options() })
      const r = cred.response
      await this.send({ id: b64(cred.rawId), clientDataJSON: b64(r.clientDataJSON), authenticatorData: b64(r.authenticatorData), signature: b64(r.signature) })
    } catch (e) { this.fail(e) }
  }

  async options() {
    const o = await (await fetch(this.optionsValue, { headers: { Accept: "application/json" }, credentials: "same-origin" })).json()
    o.challenge = unb64(o.challenge)
    return o
  }

  async send(body) {
    const res = await fetch(this.urlValue, { method: "POST", credentials: "same-origin", body: JSON.stringify(body),
      headers: { "Content-Type": "application/json", Accept: "application/json", "X-CSRF-Token": document.querySelector("meta[name=csrf-token]")?.content } })
    const data = await res.json()
    if (!res.ok) throw new Error(data.error)
    window.location.assign(data.redirect)
  }

  fail(e) {
    if (e?.name === "NotAllowedError" || e?.name === "AbortError") return // a pessoa cancelou
    if (!this.hasErrorTarget) return
    this.errorTarget.textContent = e?.message || String(e)
    this.errorTarget.hidden = false
  }
}
