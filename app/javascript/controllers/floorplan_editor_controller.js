import { Controller } from "@hotwired/stimulus"

// Editor da planta baixa: desenha um marcador por linha (ponto ou cômodo) e
// deixa arrastar. Arrastar escreve os campos x/y (e larg./alt. na alça do
// cômodo) da própria linha; os campos continuam sendo a fonte da verdade, e
// quem usa o teclado edita os números direto.
// Marcas do quadro de arrastar: o mesmo desenho do cômodo/pino da planta (FloorplanHelper), em utilitários;
// posição e tamanho por --x/--y/--w/--h (em %), arrastando = is-dragging.
const DRAG = "cursor-grab touch-none [&.is-dragging]:cursor-grabbing [&.is-dragging]:z-[3] [&.is-dragging]:shadow-[0_0_0_3px_var(--accent)]"
const ROOM = `absolute flex items-start py-[.35rem] px-2 rounded-[10px] no-underline border-[1.5px] border-[color-mix(in_srgb,var(--accent)_35%,transparent)] bg-[color-mix(in_srgb,var(--accent)_6%,transparent)] transition-[background-color,border-color,box-shadow] duration-[.4s] hover:border-accent hover:bg-[color-mix(in_srgb,var(--accent)_12%,transparent)] in-[.is-drawn]:bg-surface in-[.is-drawn]:border-line in-[.is-drawn]:shadow-[var(--shadow-card)] group-data-[night]/fp:in-[.is-drawn]:bg-[color-mix(in_srgb,var(--side)_70%,black)] group-data-[night]/fp:in-[.is-drawn]:border-[color-mix(in_srgb,var(--side)_60%,var(--accent))] group-data-[night]/fp:in-[.is-drawn]:shadow-none @max-[520px]:py-[.2rem] @max-[520px]:px-[.3rem] @max-[520px]:rounded-[7px] z-[2] text-[.72rem] font-extrabold text-ink-2 left-[var(--x)] top-[var(--y)] w-[var(--w)] h-[var(--h)] ${DRAG}`
const PIN = `absolute z-[3] grid place-items-center size-[1.6rem] rounded-full -translate-x-1/2 -translate-y-1/2 left-[var(--x)] top-[var(--y)] border-2 border-transparent text-[var(--on-accent)] bg-[image:var(--grad)] shadow-[0_4px_12px_-4px_color-mix(in_srgb,var(--ink)_35%,transparent)] ${DRAG}`
const HANDLE = "absolute -right-[6px] -bottom-[6px] size-[14px] rounded-[4px] bg-accent cursor-nwse-resize"

export default class extends Controller {
  static targets = ["canvas", "img", "image", "pins", "rooms", "js"]

  connect() {
    this.jsTargets.forEach((b) => { b.hidden = false })
    this.render()
  }

  rows() {
    return [...this.element.querySelectorAll(".dw-fpe-row")]
  }

  field(row, role) {
    return row.querySelector(`[data-role="${role}"]`)
  }

  render() {
    const url = this.imageTarget.value.trim()
    if (url && !this.previewing && /^(https:\/\/|\/)/.test(url)) { this.imgTarget.src = url; this.imgTarget.hidden = false }
    this.canvasTarget.classList.toggle("is-drawn", this.imgTarget.hidden)
    this.canvasTarget.querySelectorAll(".dw-fpe-mark").forEach((m) => m.remove())
    this.rows().forEach((row) => {
      const ref = this.field(row, "ref")
      if (!ref.value || this.field(row, "remove")?.checked) return
      const room = row.dataset.kind === "room"
      const mark = document.createElement("div")
      mark.className = `dw-fpe-mark ${room ? ROOM : PIN}`
      mark.textContent = room ? ref.selectedOptions[0].text : ""
      mark.title = ref.selectedOptions[0].text
      this.place(mark, row)
      mark.addEventListener("pointerdown", (e) => this.drag(e, row, mark, e.target.dataset.handle ? "size" : "move"))
      if (room) {
        const h = document.createElement("span")
        h.className = HANDLE
        h.dataset.handle = "1"
        mark.append(h)
      }
      this.canvasTarget.append(mark)
    })
  }

  place(mark, row) {
    const v = (k) => parseFloat(this.field(row, k)?.value) || 0
    mark.style.setProperty("--x", `${v("x")}%`)
    mark.style.setProperty("--y", `${v("y")}%`)
    if (row.dataset.kind === "room") { mark.style.setProperty("--w", `${v("w")}%`); mark.style.setProperty("--h", `${v("h")}%`) }
  }

  drag(event, row, mark, mode) {
    event.preventDefault()
    mark.setPointerCapture(event.pointerId)
    const box = this.canvasTarget.getBoundingClientRect()
    const pct = (e) => [((e.clientX - box.left) / box.width) * 100, ((e.clientY - box.top) / box.height) * 100]
    const [sx, sy] = pct(event)
    const start = Object.fromEntries(["x", "y", "w", "h"].map((k) => [k, parseFloat(this.field(row, k)?.value) || 0]))
    const set = (k, n) => { const f = this.field(row, k); if (f) f.value = Math.round(Math.min(100, Math.max(0, n)) * 10) / 10 }
    mark.classList.add("is-dragging")
    const move = (e) => {
      const [x, y] = pct(e)
      if (mode === "size") { set("w", start.w + x - sx); set("h", start.h + y - sy) } else { set("x", start.x + x - sx); set("y", start.y + y - sy) }
      this.place(mark, row)
    }
    const up = () => {
      mark.classList.remove("is-dragging")
      mark.removeEventListener("pointermove", move)
      mark.removeEventListener("pointerup", up)
    }
    mark.addEventListener("pointermove", move)
    mark.addEventListener("pointerup", up)
  }

  // Imagem escolhida no arquivo: aparece na hora (antes de salvar).
  preview(event) {
    const file = event.target.files[0]
    if (!file) return
    this.previewing = true
    this.imgTarget.src = URL.createObjectURL(file)
    this.imgTarget.hidden = false
    this.render()
  }

  addPin() { this.add(this.pinsTarget) }
  addRoom() { this.add(this.roomsTarget) }

  // Nova linha: cópia da última, com índice novo e campos limpos.
  add(list) {
    const last = list.lastElementChild
    const row = last.cloneNode(true)
    const n = Date.now()
    row.querySelectorAll("[name]").forEach((el) => {
      el.name = el.name.replace(/\[(pins|rooms)\]\[\d+\]/, `[$1][${n}]`)
      if (el.id) el.id = `${el.id}-${n}`
      if (el.dataset.role === "ref") el.value = ""
    })
    row.querySelectorAll("label[for]").forEach((l) => { l.htmlFor = `${l.htmlFor}-${n}` })
    row.querySelector("[data-role=remove]")?.closest("label")?.remove()
    list.append(row)
    this.field(row, "ref").focus()
  }
}
