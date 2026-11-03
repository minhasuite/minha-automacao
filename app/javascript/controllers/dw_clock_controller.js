import { Controller } from "@hotwired/stimulus"

// Relógio do painel (ondaB2 B10): hora no fuso do local (não o do navegador),
// no idioma da tela; anda a cada segundo (ou minuto, sem segundos).
export default class extends Controller {
  static targets = ["time", "date"]
  static values = { tz: String, h12: Boolean, seconds: Boolean, locale: String }

  connect() {
    const opts = { timeZone: this.tzValue || undefined, hour: "2-digit", minute: "2-digit", hour12: this.h12Value }
    if (this.secondsValue) opts.second = "2-digit"
    this.time = new Intl.DateTimeFormat(this.localeValue || undefined, opts)
    this.date = new Intl.DateTimeFormat(this.localeValue || undefined, { timeZone: this.tzValue || undefined, weekday: "long", day: "numeric", month: "long" })
    this.tick()
    this.timer = setInterval(() => this.tick(), this.secondsValue ? 1000 : 15000)
  }

  disconnect() { clearInterval(this.timer) }

  tick() {
    const now = new Date()
    this.timeTarget.textContent = this.time.format(now)
    this.timeTarget.setAttribute("datetime", now.toISOString())
    if (this.hasDateTarget) {
      const s = this.date.format(now)
      this.dateTarget.textContent = s.charAt(0).toUpperCase() + s.slice(1)
    }
  }
}
