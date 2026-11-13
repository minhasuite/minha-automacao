import { Controller } from "@hotwired/stimulus"

// Tela de Câmeras (cameras2): troca rápida entre câmeras.
// - Grade: setas andam pelo foco entre os cards (a linha sai da posição na tela),
//   Enter abre (é o link do card).
// - Uma câmera: ← → (ou PageUp/PageDown) e arrastar para o lado vão para a
//   anterior/seguinte; F = tela cheia (o `camera#fullscreen` do card).
// Nada disso vale com o foco num campo (data, hora).
export default class extends Controller {
  static targets = ["item", "stage"]
  static values = { prev: String, next: String }

  connect() {
    this.onKey = (e) => this.key(e)
    document.addEventListener("keydown", this.onKey)
  }

  disconnect() {
    document.removeEventListener("keydown", this.onKey)
  }

  key(e) {
    if (e.defaultPrevented || e.altKey || e.ctrlKey || e.metaKey) return
    if (e.target.closest?.("input, select, textarea, [contenteditable]")) return
    if (this.hasItemTarget) return this.gridKey(e)
    if ((e.key === "ArrowLeft" || e.key === "PageUp") && this.prevValue) { e.preventDefault(); this.go(this.prevValue) }
    else if ((e.key === "ArrowRight" || e.key === "PageDown") && this.nextValue) { e.preventDefault(); this.go(this.nextValue) }
    else if (e.key === "f" || e.key === "F") { e.preventDefault(); this.fullscreen() }
  }

  gridKey(e) {
    const items = this.itemTargets
    const i = items.indexOf(document.activeElement?.closest("[data-camera-nav-target='item']"))
    if (!["ArrowLeft", "ArrowRight", "ArrowUp", "ArrowDown"].includes(e.key)) return
    e.preventDefault()
    if (i < 0) return items[0]?.focus()
    const top = items[0].offsetTop
    const cols = Math.max(1, items.filter((x) => x.offsetTop === top).length)
    const step = { ArrowLeft: -1, ArrowRight: 1, ArrowUp: -cols, ArrowDown: cols }[e.key]
    items[Math.min(items.length - 1, Math.max(0, i + step))]?.focus()
  }

  // Enter no card da grade (não num botão dentro dele) abre a câmera.
  open(e) {
    if (e.target === e.currentTarget) this.go(e.currentTarget.dataset.url)
  }

  // Arrastar para o lado no vídeo (celular, tablet da parede).
  down(e) {
    if (e.pointerType === "mouse") return
    this.x0 = e.clientX
    this.y0 = e.clientY
  }

  up(e) {
    if (this.x0 == null) return
    const dx = e.clientX - this.x0
    const dy = e.clientY - this.y0
    this.x0 = null
    if (Math.abs(dx) < 60 || Math.abs(dx) < Math.abs(dy) * 1.5) return
    const to = dx > 0 ? this.prevValue : this.nextValue
    if (to) this.go(to)
  }

  fullscreen() {
    const tile = this.hasStageTarget && this.stageTarget.querySelector("[data-controller~='camera']")
    if (!tile) return
    this.application.getControllerForElementAndIdentifier(tile, "camera")?.fullscreen()
  }

  go(url) {
    window.Turbo ? window.Turbo.visit(url) : (window.location.href = url)
  }
}
