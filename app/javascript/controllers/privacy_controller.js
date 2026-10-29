import { Controller } from "@hotwired/stimulus"

// "Esconder valores" (botão de olho ou tecla P): borra todo .money e os
// gráficos. Preferência só deste navegador, como no meu-financeiro.
export default class extends Controller {
  toggle() {
    const on = document.documentElement.dataset.privacy !== "on"
    document.documentElement.dataset.privacy = on ? "on" : "off"
    try { localStorage.setItem("privacy", on ? "on" : "off") } catch (_) {}
  }

  key(e) {
    if (e.ctrlKey || e.metaKey || e.altKey || e.target.closest("input, textarea, select, [contenteditable]")) return
    e.preventDefault()
    this.toggle()
  }
}
