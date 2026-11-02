import { Controller } from "@hotwired/stimulus"

// Tela Expor (ondaA1): a caixa do cabeçalho marca ou desmarca a coluna inteira.
export default class extends Controller {
  column(event) {
    this.element.querySelectorAll(`input[type=checkbox][data-col="${event.params.col}"]:not(:disabled)`).forEach((box) => { box.checked = event.target.checked })
  }
}
