import { Controller } from "@hotwired/stimulus"

// Envia o formulário sozinho um pouco depois de parar de digitar (testador
// de modelo das ferramentas, Pacote 3).
export default class extends Controller {
  static values = { delay: { type: Number, default: 400 } }

  queue() {
    clearTimeout(this.timer)
    this.timer = setTimeout(() => this.element.requestSubmit(), this.delayValue)
  }

  disconnect() {
    clearTimeout(this.timer)
  }
}
