import { Controller } from "@hotwired/stimulus"

// Editor da planta baixa: desenha um marcador por linha (ponto ou cômodo) e
// deixa arrastar. Arrastar escreve os campos x/y (e larg./alt. na alça do
// cômodo) da própria linha; os campos continuam sendo a fonte da verdade, e
// quem usa o teclado edita os números direto.
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
    this.canvasTarget.classList.toggle("dw-fp-drawn", this.imgTarget.hidden)
    this.canvasTarget.querySelectorAll(".dw-fpe-mark").forEach((m) => m.remove())
    this.rows().forEach((row) => {
      const ref = this.field(row, "ref")
      if (!ref.value || this.field(row, "remove")?.checked) return
      const room = row.dataset.kind === "room"
      const mark = document.createElement("div")
      mark.className = `dw-fpe-mark ${room ? "dw-fp-room" : "dw-fp-pin dw-on"}`
      mark.textContent = room ? ref.selectedOptions[0].text : ""
      mark.title = ref.selectedOptions[0].text
      this.place(mark, row)
      mark.addEventListener("pointerdown", (e) => this.drag(e, row, mark, e.target.classList.contains("dw-fpe-handle") ? "size" : "move"))
      if (room) {
        const h = document.createElement("span")
        h.className = "dw-fpe-handle"
        mark.append(h)
      }
      this.canvasTarget.append(mark)
    })
  }

  place(mark, row) {
    const v = (k) => parseFloat(this.field(row, k)?.value) || 0
    mark.style.left = `${v("x")}%`
    mark.style.top = `${v("y")}%`
    if (row.dataset.kind === "room") { mark.style.width = `${v("w")}%`; mark.style.height = `${v("h")}%` }
  }

  drag(event, row, mark, mode) {
    event.preventDefault()
    mark.setPointerCapture(event.pointerId)
    const box = this.canvasTarget.getBoundingClientRect()
    const pct = (e) => [((e.clientX - box.left) / box.width) * 100, ((e.clientY - box.top) / box.height) * 100]
    const [sx, sy] = pct(event)
    const start = Object.fromEntries(["x", "y", "w", "h"].map((k) => [k, parseFloat(this.field(row, k)?.value) || 0]))
    const set = (k, n) => { const f = this.field(row, k); if (f) f.value = Math.round(Math.min(100, Math.max(0, n)) * 10) / 10 }
    mark.classList.add("dw-fpe-dragging")
    const move = (e) => {
      const [x, y] = pct(e)
      if (mode === "size") { set("w", start.w + x - sx); set("h", start.h + y - sy) } else { set("x", start.x + x - sx); set("y", start.y + y - sy) }
      this.place(mark, row)
    }
    const up = () => {
      mark.classList.remove("dw-fpe-dragging")
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
