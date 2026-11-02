import { Controller } from "@hotwired/stimulus"

// Cursor do gráfico do Histórico: mostra a hora e o valor de cada série no
// ponto do mouse/dedo; arrastar marca um trecho e abre a tela nessa janela.
const fmt = new Intl.NumberFormat("pt-BR", { maximumFractionDigits: 2 })

export default class extends Controller {
  static targets = ["plot", "cursor", "tip", "brush"]
  static values = { from: Number, to: Number, series: Array, url: String }

  timeAt(e) {
    const r = this.plotTarget.getBoundingClientRect()
    const f = Math.min(Math.max((e.clientX - r.left) / r.width, 0), 1)
    return { f, t: this.fromValue + f * (this.toValue - this.fromValue), x: f * r.width, w: r.width }
  }

  // Último valor da série até `t` (busca binária).
  valueAt(pts, t) {
    let lo = 0, hi = pts.length - 1, hit = null
    while (lo <= hi) {
      const mid = (lo + hi) >> 1
      if (pts[mid][0] <= t) { hit = pts[mid]; lo = mid + 1 } else hi = mid - 1
    }
    return hit && hit[1]
  }

  move(e) {
    const { t, x, w } = this.timeAt(e)
    this.cursorTarget.hidden = false
    this.cursorTarget.style.left = `${x}px`
    if (this.start != null) {
      this.brushTarget.hidden = false
      this.brushTarget.style.left = `${Math.min(this.start.x, x)}px`
      this.brushTarget.style.width = `${Math.abs(x - this.start.x)}px`
    }
    const when = new Date(t).toLocaleString("pt-BR", { day: "2-digit", month: "2-digit", hour: "2-digit", minute: "2-digit" })
    const rows = this.seriesValue.map((s) => {
      const v = this.valueAt(s.pts, t)
      return `<li><span class="hx-dot" style="background: var(--s${s.color})"></span><span>${this.escape(s.name)}</span><strong>${v == null ? "—" : fmt.format(v) + (s.unit ? " " + this.escape(s.unit) : "")}</strong></li>`
    })
    this.tipTarget.innerHTML = `<p>${when}</p><ul>${rows.join("")}</ul>`
    this.tipTarget.hidden = false
    const right = x > w * 0.6
    this.tipTarget.style.left = right ? "auto" : `${x + 12}px`
    this.tipTarget.style.right = right ? `${w - x + 12}px` : "auto"
  }

  leave() {
    this.cursorTarget.hidden = true
    this.tipTarget.hidden = true
    this.brushTarget.hidden = true
    this.start = null
  }

  down(e) {
    if (e.pointerType !== "mouse") return // no toque, arrastar é rolar a página
    this.start = this.timeAt(e)
  }

  up(e) {
    if (this.start == null) return
    const end = this.timeAt(e)
    const [a, b] = [this.start.t, end.t].sort((m, n) => m - n)
    const wide = Math.abs(end.x - this.start.x) > 8
    this.start = null
    this.brushTarget.hidden = true
    if (!wide) return
    const url = new URL(this.urlValue, window.location.origin)
    url.searchParams.set("from", new Date(a).toISOString())
    url.searchParams.set("to", new Date(b).toISOString())
    window.Turbo.visit(url.toString())
  }

  escape(s) { return String(s).replace(/[&<>"']/g, (c) => `&#${c.charCodeAt(0)};`) }
}
