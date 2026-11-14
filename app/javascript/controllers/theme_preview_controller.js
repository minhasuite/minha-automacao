import { Controller } from "@hotwired/stimulus"

// Prévia ao vivo do editor de tema (ondaB2 B11): troca as variáveis CSS da
// prévia enquanto a pessoa escolhe as cores, o papel de parede, o vidro e a fonte.
export default class extends Controller {
  static targets = ["accent", "accent2", "wall", "font", "glass", "preview"]

  update() {
    const a = this.accentTarget.value
    const b = this.accent2Target.value
    const el = this.previewTarget
    el.style.setProperty("--accent", a)
    el.style.setProperty("--accent-solid", a)
    el.style.setProperty("--accent-soft", `color-mix(in srgb, ${a} 14%, var(--surface))`)
    el.style.setProperty("--grad", `linear-gradient(135deg, ${a} 0%, ${b} 100%)`)
    el.style.setProperty("--accent2", b)
    const fonts = JSON.parse(el.dataset.fonts || "{}")
    el.style.setProperty("--font-sans", fonts[this.fontTarget.value] || "")
    el.dataset.wall = this.wallTarget.value
    el.classList.toggle("ss-wall-glass", this.glassTarget.checked)
  }
}
