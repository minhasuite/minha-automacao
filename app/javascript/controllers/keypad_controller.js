import { Controller } from "@hotwired/stimulus"

// Teclado do painel de alarme (Pacote 3): os botões escrevem no campo do
// código; depois do envio o campo fica vazio (o código nunca fica na tela).
export default class extends Controller {
  static targets = ["input"]

  press({ params: { digit } }) {
    if (this.inputTarget.value.length < 8) this.inputTarget.value += String(digit)
  }

  back() {
    this.inputTarget.value = this.inputTarget.value.slice(0, -1)
  }

  clear() {
    if (this.hasInputTarget) this.inputTarget.value = ""
  }
}
