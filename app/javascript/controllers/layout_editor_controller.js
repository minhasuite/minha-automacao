import { Controller } from "@hotwired/stimulus"
import { Turbo } from "@hotwired/turbo-rails"
import Sortable from "sortablejs"

// Editor de painel ao vivo: SortableJS para a ordem (seções e widgets, que
// podem trocar de seção) e alça própria para a largura (1 a 12 colunas da tela
// escolhida). Cada mudança vai para o rascunho (op place/resize, JSON) e a
// página se atualiza por morph; se o servidor recusar, volta ao que estava.
const VAR = { mobile: "--ss-span-m", tablet: "--ss-span-t", desktop: "--ss-span-d" }

export default class extends Controller {
  static targets = ["sections", "widgets", "status", "screenButton", "frame"]
  static values = { url: String, view: String, saved: String, failed: String }

  connect() {
    const common = { animation: 180, easing: "cubic-bezier(.2, .8, .2, 1)", ghostClass: "dw-ed-ghost", chosenClass: "dw-ed-chosen", forceFallback: true, fallbackTolerance: 4 }
    this.sortables = [
      new Sortable(this.sectionsTarget, { ...common, handle: ".dw-ed-grip-s", draggable: ".dw-ed-sec",
        onEnd: (e) => e.oldIndex !== e.newIndex && this.save({ op: "place", kind: "section", target: e.item.dataset.id, index: e.newIndex }) }),
      ...this.widgetsTargets.map((list) => new Sortable(list, { ...common, group: "dw-widgets", handle: ".dw-ed-grip:not(.dw-ed-grip-s)", draggable: ".dw-ed-w",
        onEnd: (e) => (e.from !== e.to || e.oldIndex !== e.newIndex) &&
          this.save({ op: "place", kind: "widget", target: e.item.dataset.id, index: e.newIndex, parent: e.to.dataset.section }) }))
    ]
    this.resizeStart = this.resizeStart.bind(this)
    this.element.addEventListener("pointerdown", this.resizeStart)
    this.element.addEventListener("click", (e) => this.edit(e))
    this.fit = this.fit.bind(this)
    addEventListener("resize", this.fit)
    // Começa na tela do próprio aparelho (no celular, o layout do celular).
    this.screen({ params: { screen: innerWidth < 640 ? "mobile" : innerWidth < 1024 ? "tablet" : "desktop" } })
  }

  disconnect() {
    this.sortables?.forEach((s) => s.destroy())
    this.element.removeEventListener("pointerdown", this.resizeStart)
    removeEventListener("resize", this.fit)
  }

  // A tela simulada tem a largura de verdade (celular 390, tablet 768,
  // computador 1180) e encolhe por zoom para caber no editor.
  fit() {
    const width = { mobile: 390, tablet: 768, desktop: 1180 }[this.screenName]
    const room = this.frameTarget.parentElement.clientWidth
    this.frameTarget.style.width = `${width}px`
    this.frameTarget.style.zoom = Math.min(1, room / width)
  }

  get screenName() { return this.element.dataset.ssScreen }

  screen(event) {
    this.element.dataset.ssScreen = event.params.screen
    this.screenButtonTargets.forEach((b) => b.setAttribute("aria-pressed", b.dataset.layoutEditorScreenParam === event.params.screen))
    this.labels()
    this.fit()
  }

  // "6/12" em cada bloco, da tela escolhida.
  labels() {
    this.element.querySelectorAll("[data-kind]").forEach((el) => {
      const n = this.cols(el)
      el.querySelector(":scope > .dw-ed-bar [data-cols], :scope > .dw-ed-chrome [data-cols]").textContent = `${n}/12`
    })
  }

  cols(el) {
    const v = el.style.getPropertyValue(VAR[this.screenName]).trim()
    return parseInt(v, 10) || (el.dataset.kind === "section" ? 12 : { mobile: 12, tablet: 6, desktop: 4 }[this.screenName])
  }

  resizeStart(event) {
    const handle = event.target.closest(".dw-ed-resize")
    if (!handle) return
    event.preventDefault()
    const block = handle.closest("[data-kind]")
    const grid = block.parentElement
    const colWidth = grid.getBoundingClientRect().width / 12
    const start = this.cols(block)
    const x0 = event.clientX
    let n = start
    handle.setPointerCapture(event.pointerId)
    block.classList.add("dw-ed-resizing")
    const move = (e) => {
      n = Math.min(12, Math.max(1, start + Math.round((e.clientX - x0) / colWidth)))
      block.style.setProperty(VAR[this.screenName], n)
      this.labels()
    }
    const up = () => {
      block.classList.remove("dw-ed-resizing")
      handle.removeEventListener("pointermove", move)
      handle.removeEventListener("pointerup", up)
      if (n !== start) this.save({ op: "resize", kind: block.dataset.kind, target: block.dataset.id, screen: this.screenName, cols: n })
    }
    handle.addEventListener("pointermove", move)
    handle.addEventListener("pointerup", up)
  }

  // Lápis do bloco (ou o clique no próprio card, ideia 1): abre o formulário do widget logo abaixo ou,
  // na edição na própria tela, na gaveta (link Turbo para o frame dela, sem âncora).
  edit(event) {
    let link = event.target.closest(".dw-ed-edit")
    if (!link) {
      const card = event.target.closest(".dw-ed-w")
      if (!card || event.target.closest(".dw-ed-grip, .dw-ed-resize")) return
      link = card.querySelector(":scope > .dw-ed-chrome .dw-ed-edit")
      if (!link) return
      if (!link.hash) return link.click()
    }
    if (!link.hash) return
    const target = document.getElementById(link.hash.slice(1))
    if (!target) return
    event.preventDefault()
    target.querySelector("details")?.setAttribute("open", "")
    target.closest("details")?.setAttribute("open", "")
    target.scrollIntoView({ behavior: "smooth", block: "start" })
    target.querySelector("summary")?.focus({ preventScroll: true })
  }

  async save(fields) {
    this.status("Salvando…")
    const body = new FormData()
    Object.entries({ ...fields, view_id: this.viewValue }).forEach(([k, v]) => v !== undefined && body.append(k, v))
    try {
      const r = await fetch(this.urlValue, { method: "PATCH", body, headers: { Accept: "application/json", "X-CSRF-Token": document.querySelector("meta[name=csrf-token]")?.content } })
      if (!r.ok) throw new Error((await r.json().catch(() => ({}))).errors?.[0] || this.failedValue)
      this.status(this.savedValue)
    } catch (e) {
      this.status(e.message, true)
    }
    Turbo.visit(location.href, { action: "replace" })
  }

  status(text, error = false) {
    this.statusTarget.textContent = text
    this.statusTarget.classList.toggle("text-danger", error)
    this.statusTarget.classList.toggle("text-muted", !error)
  }
}
