import { Controller } from "@hotwired/stimulus"

// visao-entrega: aviso "esta visão não aparece nesta tela" (visão com `visible_if.screen`). O aviso só
// aparece na tela em que a visão some (classes dw-hide-*); visível = troca na hora para a primeira aba
// que aparece nesta tela, sem guardar a visão escondida no histórico. Escondido = não faz nada.
export default class extends Controller {
  static values = { url: String }

  connect() {
    if (!this.urlValue || this.element.getClientRects().length === 0) return
    if (window.Turbo) window.Turbo.visit(this.urlValue, { action: "replace" })
    else window.location.replace(this.urlValue)
  }
}
