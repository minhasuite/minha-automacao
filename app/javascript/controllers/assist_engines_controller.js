import { Controller } from "@hotwired/stimulus"

// Pipeline do Assist (ondaB1): ao trocar o motor de uma etapa, mostra só os
// campos dele (cada motor vem do registro Assist::Engines).
export default class extends Controller {
  pick(event) {
    const group = event.target.closest("fieldset")
    group.querySelectorAll("[data-engine]").forEach((el) => { el.hidden = el.dataset.engine !== event.target.value })
  }
}
