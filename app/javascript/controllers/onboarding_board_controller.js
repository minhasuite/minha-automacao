import { Controller } from "@hotwired/stimulus"

// Primeira configuração, passo das áreas: arrastar o cartão do aparelho para
// a coluna da área. A caixa de seleção do cartão guarda a escolha (é ela que
// vai no formulário) e serve também para quem usa o teclado.
export default class extends Controller {
  static targets = ["column", "card"]

  start(event) {
    this.dragged = event.currentTarget
    this.dragged.classList.add("is-dragging")
    event.dataTransfer.effectAllowed = "move"
    event.dataTransfer.setData("text/plain", "")
  }

  end() {
    this.dragged?.classList.remove("is-dragging")
    this.columnTargets.forEach((c) => c.classList.remove("is-over"))
  }

  over(event) {
    event.preventDefault()
    event.currentTarget.classList.add("is-over")
  }

  leave(event) { event.currentTarget.classList.remove("is-over") }

  drop(event) {
    event.preventDefault()
    const column = event.currentTarget
    column.classList.remove("is-over")
    if (!this.dragged) return
    this.move(this.dragged, column)
    this.dragged.querySelector("select").value = column.dataset.area
  }

  // Escolha pela caixa de seleção: o cartão vai para a coluna certa.
  pick(event) {
    const column = this.columnTargets.find((c) => c.dataset.area === event.target.value)
    if (column) this.move(event.target.closest("[data-onboarding-board-target=card]"), column)
  }

  move(card, column) {
    const animate = () => column.appendChild(card)
    document.startViewTransition ? document.startViewTransition(animate) : animate()
  }
}
