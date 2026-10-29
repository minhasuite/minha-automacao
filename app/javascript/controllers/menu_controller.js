import { Controller } from "@hotwired/stimulus"

// Menu lateral: gaveta no celular, recolhido (só ícones) no desktop — a
// escolha fica no navegador e é aplicada no <head> antes de pintar.
export default class extends Controller {
  static targets = ["panel", "scrim"]

  open() {
    this.panelTarget.classList.remove("-translate-x-full")
    this.scrimTarget.setAttribute("data-open", "")
  }

  close() {
    if (!this.hasPanelTarget || window.matchMedia("(min-width: 1024px)").matches) return
    this.panelTarget.classList.add("-translate-x-full")
    this.scrimTarget.removeAttribute("data-open")
  }

  collapse() {
    const on = document.documentElement.classList.toggle("ss-collapsed")
    try { on ? localStorage.setItem("side", "collapsed") : localStorage.removeItem("side") } catch (_) {}
  }
}
