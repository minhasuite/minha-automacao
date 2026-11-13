import { Controller } from "@hotwired/stimulus"

// Câmera (no Ss::CameraTileComponent da gem): quadro a cada N segundos (só com a
// aba visível) e "Ao vivo" por WebRTC. A oferta vai ao Rails, que confere o papel
// e repassa ao go2rtc. O desenho do estado é da gem (data-state: loading, stale
// com a idade do quadro, live, offline); aqui só se troca o data-state.
//
// `autoplay` (widget com `autoplay: true`): o ao vivo abre sozinho com o card
// ao menos 25% na tela e a aba visível, fecha quando sai (ou a aba some) e
// reabre na volta. Até chegar o vídeo, a foto. Se falhar, volta às fotos e
// tenta de novo com espera crescente (5 s, 10 s, 20 s... até 2 min). Só
// `autoplayMax` (padrão 8, CameraWidget::AUTOPLAY_MAX) ao vivo abertos por
// página: os excedentes ficam na foto e entram quando abrir uma vaga. Tocar no
// botão para desligar deixa o card na foto até tocar de novo.
// Sem framework de teste de JS: o request spec confere os data-attributes e o
// comportamento foi conferido à mão no navegador (docs/dashboards.md).
const open = new Set() // controllers com ao vivo aberto (qualquer origem)
const waiting = new Set() // autoplay querendo abrir, sem vaga
const BACKOFF_MIN = 5000
const BACKOFF_MAX = 120000
const NO_VIDEO_MS = 10000

function freeSlot() {
  for (const c of [...waiting]) { waiting.delete(c); c.sync() }
}

export default class extends Controller {
  static targets = ["img", "video", "status", "liveButton", "talkButton"]
  static values = { snapshot: String, webrtc: String, interval: Number, micDenied: String,
                    autoplay: Boolean, autoplayMax: { type: Number, default: 8 } }

  connect() {
    this.imgTarget.onload = () => this.show(this.imgTarget)
    this.imgTarget.onerror = () => this.offline()
    this.retry = () => this.refresh()
    this.element.addEventListener("ss-camera:retry", this.retry)
    this.refresh()
    this.timer = setInterval(() => this.refresh(), this.intervalValue * 1000)
    if (this.autoplayValue) this.watch()
  }

  // Autoplay: na tela (>= 25%) e aba visível = ao vivo; senão, foto.
  watch() {
    this.inView = false
    this.observer = new IntersectionObserver((entries) => {
      this.inView = entries.some((e) => e.isIntersecting && e.intersectionRatio >= 0.25)
      this.sync()
    }, { threshold: [0, 0.25] })
    this.observer.observe(this.element)
    this.onVisibility = () => this.sync()
    document.addEventListener("visibilitychange", this.onVisibility)
  }

  sync() {
    if (!this.element.isConnected) return
    const want = this.autoplayValue && this.inView && !document.hidden && !this.userOff
    if (!want) {
      waiting.delete(this)
      if (this.pc && this.auto) this.stopLive()
      return
    }
    if (this.pc || this.retryTimer) return
    if (open.size >= this.autoplayMaxValue) { waiting.add(this); return }
    waiting.delete(this)
    this.startLive(true)
  }

  disconnect() {
    clearInterval(this.timer)
    this.observer?.disconnect()
    if (this.onVisibility) document.removeEventListener("visibilitychange", this.onVisibility)
    clearTimeout(this.retryTimer)
    this.retryTimer = null
    waiting.delete(this)
    this.element.removeEventListener("ss-camera:retry", this.retry)
    this.releaseMic()
    this.stopLive()
  }

  refresh() {
    if (document.hidden || this.playing) return
    // Quadro na largura da tela (celular baixa bem menos); o servidor arredonda para poucas larguras.
    const w = Math.round((this.element.clientWidth || 0) * (window.devicePixelRatio || 1))
    this.imgTarget.src = `${this.snapshotValue}?t=${Date.now()}${w > 0 && w < 1280 ? `&w=${w}` : ""}`
  }

  toggle() {
    // Com autoplay, desligar à mão segura o card na foto até ligar de novo.
    this.userOff = !!this.pc
    clearTimeout(this.retryTimer)
    this.retryTimer = null
    this.pc ? this.stopLive() : this.startLive()
  }

  async startLive(auto = false) {
    const pc = (this.pc = new RTCPeerConnection())
    this.auto = auto
    this.playing = false
    open.add(this)
    if (this.hasLiveButtonTarget) this.liveButtonTarget.setAttribute("aria-pressed", "true")
    pc.addTransceiver("video", { direction: "recvonly" })
    // ondaC2 (C10): com o microfone ligado (Falar), o áudio vai para o alto-falante da câmera (go2rtc).
    const mic = this.mic?.getAudioTracks()[0]
    mic ? pc.addTransceiver(mic, { direction: "sendrecv", streams: [this.mic] }) : pc.addTransceiver("audio", { direction: "recvonly" })
    pc.ontrack = (e) => {
      if (e.track.kind !== "video" || this.pc !== pc) return
      this.videoTarget.srcObject = e.streams[0] || new MediaStream([e.track])
      this.playing = true
      this.backoff = 0
      clearTimeout(this.noVideo)
      this.show(this.videoTarget)
    }
    pc.onconnectionstatechange = () => { if (this.pc === pc && pc.connectionState === "failed") this.liveFailed() }
    // Sem vídeo em 10 s: conta como falha (volta às fotos e tenta depois).
    clearTimeout(this.noVideo)
    this.noVideo = setTimeout(() => { if (this.pc === pc && !this.playing) this.liveFailed() }, NO_VIDEO_MS)
    try {
      await pc.setLocalDescription(await pc.createOffer())
      await this.iceGathered(pc)
      const res = await fetch(this.webrtcValue, {
        method: "POST", body: pc.localDescription.sdp,
        headers: { "Content-Type": "application/sdp", "X-CSRF-Token": document.querySelector("meta[name=csrf-token]")?.content }
      })
      if (!res.ok) throw new Error(res.status)
      await pc.setRemoteDescription({ type: "answer", sdp: await res.text() })
    } catch {
      if (this.pc === pc) this.liveFailed()
    }
  }

  // Falar (áudio de duas vias): liga o microfone e refaz o ao vivo mandando o áudio.
  async talk() {
    if (this.mic) {
      this.releaseMic()
      if (this.pc) { this.stopLive(); this.startLive() }
      return
    }
    try {
      this.mic = await navigator.mediaDevices.getUserMedia({ audio: { echoCancellation: true, noiseSuppression: true } })
    } catch {
      this.status(this.micDeniedValue)
      return
    }
    this.talkButtonTarget.setAttribute("aria-pressed", "true")
    if (this.pc) this.stopLive()
    await this.startLive()
  }

  releaseMic() {
    this.mic?.getTracks().forEach((t) => t.stop())
    this.mic = null
    if (this.hasTalkButtonTarget) this.talkButtonTarget.setAttribute("aria-pressed", "false")
  }

  iceGathered(pc) {
    if (pc.iceGatheringState === "complete") return Promise.resolve()
    return new Promise((resolve) => {
      setTimeout(resolve, 2000)
      pc.onicegatheringstatechange = () => { if (pc.iceGatheringState === "complete") resolve() }
    })
  }

  liveFailed() {
    const auto = this.auto
    this.stopLive()
    setTimeout(() => this.refresh(), 1500)
    if (!auto || !this.autoplayValue) return
    // Espera crescente para não martelar o go2rtc/DVR.
    this.backoff = Math.min(BACKOFF_MAX, this.backoff ? this.backoff * 2 : BACKOFF_MIN)
    clearTimeout(this.retryTimer)
    this.retryTimer = setTimeout(() => { this.retryTimer = null; this.sync() }, this.backoff)
  }

  stopLive() {
    if (!this.pc) return
    clearTimeout(this.noVideo)
    this.pc.close()
    this.pc = null
    this.auto = false
    this.playing = false
    if (open.delete(this)) freeSlot()
    this.videoTarget.srcObject = null
    this.videoTarget.hidden = true
    if (this.hasLiveButtonTarget) this.liveButtonTarget.setAttribute("aria-pressed", "false")
    this.refresh()
  }

  show(el) {
    // Com o vídeo tocando a foto fica escondida; enquanto ele não chega, a foto vale.
    if (el === this.imgTarget && this.playing) return
    this.imgTarget.hidden = el !== this.imgTarget
    this.videoTarget.hidden = el !== this.videoTarget
    // Quadro novo: a idade volta a zero (o ss-camera conta de novo).
    if (el === this.imgTarget) this.element.dataset.ssCameraAgeValue = 0
    this.element.dataset.state = el === this.videoTarget ? "live" : "stale"
  }

  offline() {
    if (this.playing) return
    this.imgTarget.hidden = true
    this.element.dataset.state = "offline"
  }

  // Aviso fora do quadro (microfone negado), quando a tela tem onde mostrar.
  status(text) {
    if (!this.hasStatusTarget) return
    this.statusTarget.textContent = text
    this.statusTarget.hidden = false
  }
}
