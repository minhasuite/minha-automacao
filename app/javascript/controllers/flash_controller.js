import { Controller } from "@hotwired/stimulus"

// Aviso some sozinho quando a barra de tempo acaba (só os de sucesso) ou no X.
export default class extends Controller {
  close() {
    this.element.style.transition = "opacity .25s ease, transform .25s ease"
    this.element.style.opacity = "0"
    this.element.style.transform = "translateY(-6px)"
    setTimeout(() => this.element.remove(), 250)
  }
}
