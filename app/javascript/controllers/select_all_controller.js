import { Controller } from "@hotwired/stimulus"

// "Marcar todas" das ações em massa: marca as caixas ligadas a este formulário
// (`form="<id>"`, ficam nas linhas da lista, fora dele).
export default class extends Controller {
  toggle(event) {
    document.querySelectorAll(`input[type=checkbox][form="${this.element.id}"]`).forEach((box) => { box.checked = event.target.checked })
  }
}
