import { Controller } from "@hotwired/stimulus"

// Toque, segurar e duplo toque de um widget (ondaB2 B9; tap/hold/double_tap_action
// do HA). O servidor já deixou um elemento escondido por gesto
// ([data-gesture=tap|hold|double_tap]): formulário de comando (Turbo cuida da
// confirmação), link (detalhes, visão, URL) ou marcador (assistente, nada).
// Controles de dentro do card (botões, links, campos, [data-no-gesture]) não disparam.
const HOLD_MS = 500
const DOUBLE_MS = 250

export default class extends Controller {
  static values = { kinds: String }

  connect() {
    this.kinds = new Set(this.kindsValue.split(" "))
    this.onDown = this.down.bind(this)
    this.onUp = this.cancelHold.bind(this)
    this.onClick = this.click.bind(this)
    this.element.addEventListener("pointerdown", this.onDown)
    for (const e of ["pointerup", "pointerleave", "pointercancel"]) this.element.addEventListener(e, this.onUp)
    this.element.addEventListener("click", this.onClick, true)
    if (this.kinds.has("tap") || this.kinds.has("double_tap")) this.element.classList.add("is-gesture-tap")
  }

  disconnect() {
    this.cancelHold()
    clearTimeout(this.pending)
    this.element.removeEventListener("pointerdown", this.onDown)
    for (const e of ["pointerup", "pointerleave", "pointercancel"]) this.element.removeEventListener(e, this.onUp)
    this.element.removeEventListener("click", this.onClick, true)
  }

  own(target) {
    const control = target.closest("button, a, input, select, textarea, label, [data-no-gesture]")
    return !control || !this.element.contains(control) || control === this.element
  }

  down(e) {
    if (!this.kinds.has("hold") || e.button > 0 || !this.own(e.target)) return
    this.held = false
    this.element.classList.add("is-gesture-hold")
    this.timer = setTimeout(() => {
      this.held = true
      this.element.classList.remove("is-gesture-hold")
      navigator.vibrate?.(12)
      this.run("hold")
    }, HOLD_MS)
  }

  cancelHold() {
    clearTimeout(this.timer)
    this.element.classList.remove("is-gesture-hold")
  }

  click(e) {
    if (this.held) {
      this.held = false
      e.preventDefault()
      e.stopPropagation()
      return
    }
    if (!this.own(e.target) || !(this.kinds.has("tap") || this.kinds.has("double_tap"))) return
    e.preventDefault()
    e.stopPropagation()
    if (!this.kinds.has("double_tap")) return this.run("tap")
    if (this.pending) {
      clearTimeout(this.pending)
      this.pending = null
      return this.run("double_tap")
    }
    this.pending = setTimeout(() => { this.pending = null; this.run("tap") }, DOUBLE_MS)
  }

  run(gesture) {
    const el = this.element.querySelector(`[data-gesture="${gesture}"]`)
    if (!el) return
    if (el.tagName === "FORM") return el.requestSubmit()
    if (el.dataset.kind === "assist") return document.querySelector('[data-action~="assist#open"]')?.click()
    if (el.tagName !== "A") return
    if (el.dataset.confirm && !window.confirm(el.dataset.confirm)) return
    el.click()
  }
}
