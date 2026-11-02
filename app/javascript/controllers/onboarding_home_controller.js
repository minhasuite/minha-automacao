import { Controller } from "@hotwired/stimulus"

// Primeira configuração, passo da casa: marca o fuso do navegador (local
// novo) e pega a localização pelo navegador (preenche latitude e longitude).
export default class extends Controller {
  static targets = ["zone", "lat", "lon", "status"]
  static values = { found: String, denied: String }

  connect() {
    if (this.zoneTarget.dataset.fresh !== "true") return
    try {
      const tz = Intl.DateTimeFormat().resolvedOptions().timeZone
      if ([...this.zoneTarget.options].some((o) => o.value === tz)) this.zoneTarget.value = tz
    } catch (_) {}
  }

  locate() {
    if (!navigator.geolocation) { this.statusTarget.textContent = this.deniedValue; return }
    navigator.geolocation.getCurrentPosition(
      (pos) => {
        this.latTarget.value = pos.coords.latitude.toFixed(4)
        this.lonTarget.value = pos.coords.longitude.toFixed(4)
        this.statusTarget.textContent = this.foundValue
      },
      () => { this.statusTarget.textContent = this.deniedValue },
      { timeout: 10000, maximumAge: 600000 }
    )
  }
}
