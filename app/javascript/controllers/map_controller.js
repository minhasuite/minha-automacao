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
    const color = (i) => css.getPropertyValue(`--s${i % 6}`).trim() || "#5a45e8"
    const accent = css.getPropertyValue("--accent").trim() || "#5a45e8"
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
        className: "mp-pin", iconSize: [40, 40], iconAnchor: [20, 20],
        html: `<span class="mp-avatar ${p.home ? "mp-home" : ""} ${p.precise ? "" : "mp-approx"}" style="--mp-c: ${color(i)}">${esc(p.initials)}</span>`
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
