import { Controller } from "@hotwired/stimulus"

// Recarrega a cada N ms: turbo-frame com src (log do app) recarrega o
// quadro; qualquer outro elemento recarrega a página (app instalando).
export default class extends Controller {
  static values = { every: { type: Number, default: 5000 } }

  connect() {
    this.timer = setInterval(() => {
      if (document.hidden) return
      if (this.element.tagName === "TURBO-FRAME") this.element.reload()
      else window.Turbo.visit(window.location.href, { action: "replace" })
    }, this.everyValue)
  }

  disconnect() { clearInterval(this.timer) }
}
