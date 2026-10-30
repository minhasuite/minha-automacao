import { Controller } from "@hotwired/stimulus"

// Copia o texto do campo (link de convite, chave de integração) e avisa no botão.
export default class extends Controller {
  static targets = ["source"]

  async copy(event) {
    const button = event.currentTarget
    this.sourceTarget.select()
    try { await navigator.clipboard.writeText(this.sourceTarget.value) } catch (_) { document.execCommand("copy") }
    const text = button.lastChild.textContent
    button.lastChild.textContent = "Copiado"
    setTimeout(() => { button.lastChild.textContent = text }, 2000)
  }
}
