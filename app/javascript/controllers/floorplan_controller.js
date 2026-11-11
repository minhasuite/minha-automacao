import { Controller } from "@hotwired/stimulus"

// Planta baixa (widget floorplan): troca de andar e modo noite. O quadro se
// recarrega a cada mudança de ponto, então a escolha fica neste navegador
// (por widget, por 12 horas). Sem escolha, a noite segue o tema escuro ou a
// noite do local (o <body> ganha dw-night pelo sol/janela do tema do painel).
export default class extends Controller {
  static targets = ["tab", "layer", "nightButton"]
  static values = { key: String }

  connect() {
    // Esqueleto enquanto a imagem da planta carrega.
    this.element.querySelectorAll(".dw-fp-img").forEach((img) => {
      const done = () => img.setAttribute("data-loaded", "")
      img.complete ? done() : img.addEventListener("load", done, { once: true })
    })
    const saved = this.read()
    this.select(saved.layer || 0)
    const dark = document.documentElement.dataset.theme === "dark" ||
      (!document.documentElement.dataset.theme && matchMedia("(prefers-color-scheme: dark)").matches)
    const fresh = saved.nightAt && Date.now() - saved.nightAt < 12 * 3600 * 1000
    this.applyNight(fresh ? saved.night : (dark || document.body.classList.contains("dw-night")))
  }

  show(event) {
    this.select(event.params.index)
    this.write({ layer: event.params.index })
  }

  night() {
    const on = !this.element.hasAttribute("data-night")
    this.applyNight(on)
    this.write({ night: on, nightAt: Date.now() })
  }

  select(index) {
    if (index >= this.layerTargets.length) index = 0
    this.layerTargets.forEach((l, i) => { l.hidden = i !== index })
    this.tabTargets.forEach((t, i) => t.setAttribute("aria-selected", i === index))
  }

  applyNight(on) {
    this.element.toggleAttribute("data-night", on)
    if (this.hasNightButtonTarget) this.nightButtonTarget.setAttribute("aria-pressed", on)
  }

  read() {
    try { return JSON.parse(localStorage.getItem(`fp:${this.keyValue}`)) || {} } catch (_) { return {} }
  }

  write(patch) {
    try { localStorage.setItem(`fp:${this.keyValue}`, JSON.stringify({ ...this.read(), ...patch })) } catch (_) {}
  }
}
