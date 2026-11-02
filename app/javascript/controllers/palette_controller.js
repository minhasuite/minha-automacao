import { Controller } from "@hotwired/stimulus"

// Paleta de comandos (Ctrl+K / ⌘K, ou qualquer [data-palette-open]): o
// quadro de resultados vem de /busca?q= (fontes do registro Search no
// servidor, que já cortam pelo papel). Setas andam, Enter abre ou executa.
export default class extends Controller {
  static targets = ["input", "frame"]
  static values = { url: String }

  connect() {
    this.opener = (e) => { if (e.target.closest("[data-palette-open]")) { e.preventDefault(); this.open() } }
    document.addEventListener("click", this.opener)
  }

  disconnect() {
    document.removeEventListener("click", this.opener)
  }

  open(event) {
    event?.preventDefault()
    if (this.element.open) return this.inputTarget.select()
    this.element.showModal()
    this.inputTarget.value = ""
    this.load("")
    this.inputTarget.focus()
  }

  backdrop(event) {
    if (event.target === this.element) this.element.close()
  }

  search() {
    clearTimeout(this.timer)
    this.timer = setTimeout(() => this.load(this.inputTarget.value), 140)
  }

  fill(event) {
    this.inputTarget.value = event.params.text
    this.load(event.params.text)
    this.inputTarget.focus()
  }

  load(q) {
    this.frameTarget.src = `${this.urlValue}?q=${encodeURIComponent(q.trim())}`
  }

  items() {
    return [...this.element.querySelectorAll("[data-palette-item]")]
  }

  nav(event) {
    const items = this.items()
    const i = items.indexOf(document.activeElement)
    if (event.key === "ArrowDown" || event.key === "ArrowUp") {
      event.preventDefault()
      const next = event.key === "ArrowDown" ? (i + 1) % items.length : (i <= 0 ? items.length - 1 : i - 1)
      items[next]?.focus()
    } else if (event.key === "Enter" && document.activeElement === this.inputTarget) {
      event.preventDefault()
      items[0]?.click()
    } else if (event.key.length === 1 && i >= 0 && !event.ctrlKey && !event.metaKey) {
      this.inputTarget.focus() // digitar em cima de um item volta para a busca
    }
  }

  submit(event) {
    event.preventDefault()
    this.items()[0]?.click()
  }
}
