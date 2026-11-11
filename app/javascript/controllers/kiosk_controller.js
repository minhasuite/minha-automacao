import { Controller } from "@hotwired/stimulus"

// Quiosque (tablet de parede): mantém a tela acesa (Wake Lock), esconde o
// cursor parado, liga o protetor de tela depois de `idle` minutos sem toque e
// acorda no toque/tecla ou quando o ponto de movimento escolhido muda
// (evento dw:point-changed do tempo real do painel).
export default class extends Controller {
  static targets = ["saver", "slide", "clock", "date", "bar", "bigClock", "bigDate"]
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
    document.body.classList.remove("ma-kiosk-idle")
    clearTimeout(this.cursorTimer)
    this.cursorTimer = setTimeout(() => document.body.classList.add("ma-kiosk-idle"), 3000)
    clearTimeout(this.idleTimer)
    if (this.saverValue !== "off") this.idleTimer = setTimeout(() => this.sleep(), this.idleValue * 60000)
  }

  // Movimento no ponto escolhido: acorda o protetor e, aceso, adia o próximo (tem gente olhando).
  pointChanged(event) {
    if (!this.motionValue || event.detail !== this.motionValue) return
    if (!this.saverTarget.hidden) this.wake()
    this.activity()
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
    img.onload = () => { this.slideTarget.style.backgroundImage = `url("${src}")`; this.slideTarget.classList.add("ma-saver-on") }
    img.src = src
  }

  clock() {
    const now = new Date()
    const lang = document.documentElement.lang || "pt-BR"
    const time = now.toLocaleTimeString(lang, { hour: "2-digit", minute: "2-digit" })
    const date = now.toLocaleDateString(lang, { weekday: "long", day: "numeric", month: "long" })
    this.clockTarget.textContent = time
    this.dateTarget.textContent = date
    if (this.hasBigClockTarget) this.bigClockTarget.textContent = time
    if (this.hasBigDateTarget) this.bigDateTarget.textContent = date
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
