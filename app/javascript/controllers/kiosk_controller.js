import { Controller } from "@hotwired/stimulus"

// Quiosque (tablet de parede): mantém a tela acesa (Wake Lock), esconde o
// cursor parado, liga o protetor de tela depois de `idle` minutos sem toque e
// acorda no toque/tecla ou quando o ponto de movimento escolhido muda
// (evento dw:point-changed do tempo real do painel).
export default class extends Controller {
  static targets = ["saver", "slide", "clock", "date", "bar"]
  static values = { idle: Number, saver: String, motion: String, dim: Boolean, slides: Array }

  connect() {
    this.activity = this.activity.bind(this)
    this.visibility = this.visibility.bind(this)
    this.pointChanged = this.pointChanged.bind(this)
    ;["pointerdown", "pointermove", "keydown", "wheel"].forEach((e) => addEventListener(e, this.activity, { passive: true }))
    document.addEventListener("visibilitychange", this.visibility)
    document.addEventListener("dw:point-changed", this.pointChanged)
    this.tick = setInterval(() => this.clock(), 1000)
    this.clock()
    this.lock()
    this.activity()
  }

  disconnect() {
    ;["pointerdown", "pointermove", "keydown", "wheel"].forEach((e) => removeEventListener(e, this.activity))
    document.removeEventListener("visibilitychange", this.visibility)
    document.removeEventListener("dw:point-changed", this.pointChanged)
    clearInterval(this.tick)
    clearInterval(this.slideTimer)
    clearTimeout(this.idleTimer)
    clearTimeout(this.cursorTimer)
    this.wakeLock?.release().catch(() => {})
  }

  activity(event) {
    if (event && !this.saverTarget.hidden) {
      if (event.type === "pointermove") return // só toque, tecla ou roda acordam
      // O toque que acorda não chega no painel (não liga uma luz sem querer).
      addEventListener("click", (e) => { e.preventDefault(); e.stopPropagation() }, { capture: true, once: true })
      setTimeout(() => this.wake(), 0)
    }
    document.body.classList.remove("ss-kiosk-idle")
    clearTimeout(this.cursorTimer)
    this.cursorTimer = setTimeout(() => document.body.classList.add("ss-kiosk-idle"), 3000)
    clearTimeout(this.idleTimer)
    if (this.saverValue !== "off") this.idleTimer = setTimeout(() => this.sleep(), this.idleValue * 60000)
  }

  pointChanged(event) {
    if (this.motionValue && event.detail === this.motionValue && !this.saverTarget.hidden) { this.wake(); this.activity() }
  }

  sleep() {
    if (this.saverValue === "off") return
    this.saverTarget.hidden = false
    this.slideIndex = 0
    this.slide()
    if (this.slidesValue.length) this.slideTimer = setInterval(() => this.slide(), 8000)
  }

  wake() {
    this.saverTarget.hidden = true
    clearInterval(this.slideTimer)
  }

  // Câmeras: quadro novo a cada volta; fotos: a próxima da lista.
  slide() {
    const list = this.slidesValue
    if (!list.length) return
    const url = list[this.slideIndex++ % list.length]
    const src = this.saverValue === "cameras" ? `${url}?t=${Date.now()}` : url
    const img = new Image()
    img.onload = () => { this.slideTarget.style.backgroundImage = `url("${src}")`; this.slideTarget.classList.add("ss-saver-on") }
    img.src = src
  }

  clock() {
    const now = new Date()
    this.clockTarget.textContent = now.toLocaleTimeString("pt-BR", { hour: "2-digit", minute: "2-digit" })
    this.dateTarget.textContent = now.toLocaleDateString("pt-BR", { weekday: "long", day: "numeric", month: "long" })
  }

  async lock() {
    try { if ("wakeLock" in navigator && document.visibilityState === "visible") this.wakeLock = await navigator.wakeLock.request("screen") } catch (_) {}
  }

  visibility() {
    if (document.visibilityState === "visible") this.lock()
  }

  fullscreen() {
    if (document.fullscreenElement) document.exitFullscreen()
    else document.documentElement.requestFullscreen?.().catch(() => {})
  }
}
