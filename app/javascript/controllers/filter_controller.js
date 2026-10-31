import { Controller } from "@hotwired/stimulus"

// Busca na própria lista (sem ir ao servidor): esconde os itens cujo texto não
// tem todas as palavras digitadas, sem acento e sem caixa. Os escondidos
// continuam no formulário (salvar não perde nada).
const norm = (s) => s.normalize("NFD").replace(/[\u0300-\u036f]/g, "").toLowerCase()

export default class extends Controller {
  static targets = ["input", "item", "empty"]

  apply() {
    const words = norm(this.inputTarget.value).split(/\s+/).filter(Boolean)
    let shown = 0
    this.itemTargets.forEach((item) => {
      const hit = words.every((w) => norm(item.textContent + " " + [...item.querySelectorAll("input[placeholder]")].map((i) => i.placeholder).join(" ")).includes(w))
      item.style.display = hit ? "" : "none" // [hidden] perde para o display das listas
      if (hit) shown++
    })
    if (this.hasEmptyTarget) this.emptyTarget.hidden = shown > 0
  }

  clear() {
    this.inputTarget.value = ""
    this.apply()
    this.inputTarget.focus()
  }
}
