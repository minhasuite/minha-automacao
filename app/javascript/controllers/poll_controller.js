import { Controller } from "@hotwired/stimulus"

// Pergunta ao servidor a cada 3 s (login por QR, varredura em andamento);
// quando ele devolve {url}, abre essa página.
export default class extends Controller {
  static values = { url: String, every: { type: Number, default: 3000 } }

  connect() { this.timer = setInterval(() => this.check(), this.everyValue) }
  disconnect() { clearInterval(this.timer) }

  async check() {
    if (this.busy) return
    this.busy = true
    try {
      const r = await fetch(this.urlValue, { headers: { Accept: "application/json" } })
      const j = r.ok ? await r.json() : {}
      if (j.url) { clearInterval(this.timer); window.Turbo.visit(j.url) }
      // {error}: para de perguntar e mostra (ex.: "QR expirou, gere outro.").
      const status = this.element.querySelector("[role=status]")
      if (j.error && status) { clearInterval(this.timer); status.textContent = j.error }
    } finally { this.busy = false }
  }
}
