import { Controller } from "@hotwired/stimulus"

// Mapa (Leaflet 1.9.4 + tiles do OpenStreetMap, carregados só quando há um
// mapa na tela): zonas em círculo, pessoas com as iniciais e o trajeto do dia.
const CSS = "https://cdn.jsdelivr.net/npm/leaflet@1.9.4/dist/leaflet.css"
const CSS_SRI = "sha256-p4NxAoJBhIIN+hmNHrzRCf9tD/miZyoHS5obTRR9BMY="
const esc = (s) => String(s ?? "").replace(/[&<>"']/g, (c) => `&#${c.charCodeAt(0)};`)

export default class extends Controller {
  static targets = ["canvas", "fallback"]
  static values = { data: Object }

  async connect() {
    if (!document.querySelector(`link[href="${CSS}"]`)) {
      const link = Object.assign(document.createElement("link"), { rel: "stylesheet", href: CSS, integrity: CSS_SRI, crossOrigin: "" })
      document.head.append(link)
    }
    let L
    try { L = await import("leaflet") } catch { this.fallbackTarget.hidden = false; return }
    if (!this.element.isConnected) return
    const d = this.dataValue
    const css = getComputedStyle(document.documentElement)
    // Cor de cada pessoa: a série da gem (a mesma no pino, no trajeto e na lista).
    const accent = css.getPropertyValue("--accent").trim()
    const color = (i) => css.getPropertyValue(`--series-${(i % 6) + 1}`).trim() || accent
    this.map = L.map(this.canvasTarget, { scrollWheelZoom: false }).setView(d.center, 15)
    L.tileLayer("https://tile.openstreetmap.org/{z}/{x}/{y}.png", {
      maxZoom: 19, attribution: "&copy; <a href=\"https://www.openstreetmap.org/copyright\">OpenStreetMap</a>"
    }).addTo(this.map)
    this.marks = {}
    const bounds = []
    d.zones.forEach((z) => {
      const c = L.circle([z.lat, z.lon], { radius: z.radius, color: z.home ? accent : color(3), weight: 2, fillOpacity: 0.12 }).addTo(this.map)
      c.bindTooltip(`${esc(z.name)} · ${z.count} ${esc(d.texts?.people ?? "pessoa(s)")}`)
      this.marks[z.id] = c
      bounds.push([z.lat, z.lon])
    })
    d.people.forEach((p, i) => {
      if (p.track && p.track.length > 1) {
        L.polyline(p.track.map((t) => [t[0], t[1]]), { color: color(i), weight: 4, opacity: 0.75, lineCap: "round" }).addTo(this.map)
        p.track.forEach((t) => bounds.push([t[0], t[1]]))
      }
      if (p.lat == null) return
      const icon = L.divIcon({
        className: "bg-transparent border-0", iconSize: [40, 40], iconAnchor: [20, 20],
        html: `<span class="grid place-items-center flex-none rounded-full font-bold text-[.8rem] leading-none text-[var(--on-accent)] bg-[var(--mp-c,var(--accent))] border-[3px] border-surface size-10 ${p.home ? "shadow-[0_0_0_2px_var(--success),0_8px_18px_-8px_color-mix(in_srgb,var(--ink)_50%,transparent)]" : "shadow-[0_0_0_2px_var(--mp-c,var(--accent)),0_8px_18px_-8px_color-mix(in_srgb,var(--ink)_50%,transparent)]"} ${p.precise ? "" : "opacity-85 border-dashed"}" style="--mp-c: ${color(i)}">${esc(p.initials)}</span>`
      })
      const m = L.marker([p.lat, p.lon], { icon, title: p.name }).addTo(this.map)
      m.bindPopup(`<strong>${esc(p.name)}</strong><br>${esc(p.zone || d.texts?.no_reading || "")}${p.precise ? "" : ` (${esc(d.texts?.approx ?? "")})`}`)
      if (p.precise && p.accuracy) L.circle([p.lat, p.lon], { radius: p.accuracy, color: color(i), weight: 1, fillOpacity: 0.08, interactive: false }).addTo(this.map)
      this.marks[p.id] = m
      bounds.push([p.lat, p.lon])
    })
    if (bounds.length > 1) this.map.fitBounds(bounds, { padding: [36, 36], maxZoom: 16 })
    // Roda do mouse só depois de um clique no mapa (não rouba a rolagem da página).
    this.map.on("click", () => this.map.scrollWheelZoom.enable())
  }

  focus({ params: { id } }) {
    const m = this.marks?.[id]
    if (!m) return
    this.map.flyTo(m.getLatLng(), Math.max(this.map.getZoom(), 16), { duration: 0.6 })
    m.openPopup?.()
    this.element.scrollIntoView({ behavior: "smooth", block: "nearest" })
  }

  disconnect() { this.map?.remove() }
}
