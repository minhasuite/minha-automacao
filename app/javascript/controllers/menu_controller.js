import { Controller } from "@hotwired/stimulus"

// Menu lateral: gaveta no celular, recolhido (só ícones) no desktop — a
// escolha fica no navegador e é aplicada no <head> antes de pintar.
export default class extends Controller {
  static targets = ["panel", "scrim", "toggle"]

  open() {
    this.panelTarget.classList.remove("-translate-x-full")
    this.scrimTarget.setAttribute("data-open", "")
    if (this.hasToggleTarget) this.toggleTarget.setAttribute("aria-expanded", "true")
    this.panelTarget.querySelector("a[aria-current], nav a")?.focus({ preventScroll: true })
  }

  close() {
    if (!this.hasPanelTarget || window.matchMedia("(min-width: 1024px)").matches || !this.scrimTarget.hasAttribute("data-open")) return
    this.panelTarget.classList.add("-translate-x-full")
    this.scrimTarget.removeAttribute("data-open")
    if (this.hasToggleTarget) { this.toggleTarget.setAttribute("aria-expanded", "false"); this.toggleTarget.focus() }
  }

  collapse() {
    const on = document.documentElement.classList.toggle("ss-collapsed")
    try { on ? localStorage.setItem("side", "collapsed") : localStorage.removeItem("side") } catch (_) {}
  }
}
