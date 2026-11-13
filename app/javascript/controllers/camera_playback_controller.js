import { Controller } from "@hotwired/stimulus"

// Reprodução do DVR na tela da câmera (cameras2). Tocar a partir de um horário (o
// campo de hora, um evento da lista ou um toque na faixa do dia), pular ±30 s e
// voltar ao ao vivo. O Rails põe a fonte de reprodução no go2rtc
// (`POST /cameras/:id/reproduzir` → nome do stream) e o card toca pelo mesmo
// caminho do ao vivo (`camera#source`: WebRTC em casa, MSE fora). Velocidade 1x.
// A posição é o início pedido mais o tempo desde que o vídeo chegou.
export default class extends Controller {
  static targets = ["tile", "time", "day", "position", "liveButton", "jump", "error"]
  static values = { url: String, zone: String, locale: String }

  connect() {
    this.onPlaying = (e) => {
      if (!e.detail?.pb || e.detail.pb !== this.pb) return
      this.playingSince = Date.now()
      this.tick()
    }
    this.element.addEventListener("camera:playing", this.onPlaying)
    this.onBand = (e) => this.bandClick(e)
    this.element.addEventListener("click", this.onBand)
  }

  disconnect() {
    this.element.removeEventListener("camera:playing", this.onPlaying)
    this.element.removeEventListener("click", this.onBand)
    clearInterval(this.clock)
    this.stop()
  }

  get camera() {
    return this.application.getControllerForElementAndIdentifier(this.tileTarget, "camera")
  }

  // Botão "Tocar": dia + hora dos campos.
  playTime() {
    const day = this.hasDayTarget ? this.dayTarget.value : ""
    const time = this.hasTimeTarget ? this.timeTarget.value : ""
    if (!day || !time) return
    this.play(`${day} ${time.length === 5 ? `${time}:00` : time}`)
  }

  // Evento da lista (data-camera-playback-at-param = ISO).
  playAt(e) {
    this.play(e.params.at)
  }

  // Toque na faixa do dia (Ss::StateBandsComponent): a posição vira o horário.
  bandClick(e) {
    const bar = e.target.closest?.(".ss-sb-bar")
    const root = bar?.closest("[data-ss-state-bands-from-value]")
    if (!bar || !root) return
    const from = Number(root.dataset.ssStateBandsFromValue)
    const to = Number(root.dataset.ssStateBandsToValue)
    const r = bar.getBoundingClientRect()
    const at = new Date(from + ((e.clientX - r.left) / r.width) * (to - from))
    if (at > new Date()) return
    this.play(at.toISOString())
  }

  jump(e) {
    if (!this.start) return
    const s = Number(e.params.seconds || 0)
    const at = new Date(this.position().getTime() + s * 1000)
    this.play((at > new Date() ? new Date(Date.now() - 5000) : at).toISOString())
  }

  async play(inicio) {
    this.error("")
    const body = new FormData()
    body.append("inicio", inicio)
    if (this.pb) body.append("troca", this.pb)
    const res = await fetch(this.urlValue, {
      method: "POST", body, headers: { Accept: "application/json", "X-CSRF-Token": document.querySelector("meta[name=csrf-token]")?.content }
    }).catch(() => null)
    const data = await res?.json().catch(() => null)
    if (!res?.ok || !data?.stream) return this.error(data?.error || "")
    this.pb = data.stream
    this.start = new Date(data.start)
    this.playingSince = null
    this.state(true)
    this.camera?.source(this.pb)
    this.tick()
  }

  live() {
    this.stop()
    this.camera?.source(null)
  }

  stop() {
    if (!this.pb) return
    const pb = this.pb
    this.pb = null
    this.start = null
    this.state(false)
    fetch(`${this.urlValue}?pb=${encodeURIComponent(pb)}`, {
      method: "DELETE", headers: { "X-CSRF-Token": document.querySelector("meta[name=csrf-token]")?.content }, keepalive: true
    }).catch(() => {})
  }

  position() {
    const extra = this.playingSince ? Date.now() - this.playingSince : 0
    return new Date(this.start.getTime() + extra)
  }

  state(on) {
    if (this.hasLiveButtonTarget) this.liveButtonTarget.hidden = !on
    this.jumpTargets.forEach((b) => { b.disabled = !on })
    clearInterval(this.clock)
    if (on) this.clock = setInterval(() => this.tick(), 1000)
    else if (this.hasPositionTarget) this.positionTarget.textContent = ""
  }

  tick() {
    if (!this.start || !this.hasPositionTarget) return
    const fmt = new Intl.DateTimeFormat(this.localeValue || undefined, {
      timeZone: this.zoneValue || undefined, day: "2-digit", month: "2-digit", hour: "2-digit", minute: "2-digit", second: "2-digit"
    })
    this.positionTarget.textContent = fmt.format(this.position())
  }

  error(text) {
    if (!this.hasErrorTarget) return
    this.errorTarget.textContent = text
    this.errorTarget.hidden = !text
  }
}
