import { Controller } from "@hotwired/stimulus"

// "Marcar todas" das ações em massa: marca as caixas `ids[]` da lista dentro do
// elemento do controller (a barra .ss-bulk aparece e conta os marcados pelo CSS).
export default class extends Controller {
  toggle(event) {
    this.element.querySelectorAll('input[type=checkbox][name="ids[]"]').forEach((box) => { box.checked = event.target.checked })
  }
}
