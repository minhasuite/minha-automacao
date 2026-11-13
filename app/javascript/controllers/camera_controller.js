import { Controller } from "@hotwired/stimulus"

// Câmera (no Ss::CameraTileComponent da gem): quadro a cada N segundos (só com a
// aba visível) e "Ao vivo". O desenho do estado é da gem (data-state: loading,
// stale com a idade do quadro, live, offline); aqui só se troca o data-state.
//
// Ao vivo (cameras2): primeiro WebRTC (a oferta vai ao Rails, que confere o papel
// e repassa ao go2rtc; a mídia vem pela 8555, só na rede de casa). Sem vídeo em
// WEBRTC_MS (fora de casa), cai para o MSE do go2rtc por WebSocket através do
// Rails (`/cameras/:id/mse`); sem MSE no navegador (iPhone antigo), o HLS pelo
// link assinado (`/cameras/:id/hls`). Depois de um WebRTC que não conectou, a
// página vai direto ao MSE por WEBRTC_SKIP_MS (as outras câmeras não esperam).
// `source(pb)` troca o vídeo pela reprodução do DVR (`?pb=` nos mesmos caminhos).
//
// `autoplay` (widget com `autoplay: true`, tela de Câmeras): o ao vivo abre
// sozinho com o card ao menos 25% na tela e a aba visível, fecha quando sai (ou a
// aba some) e reabre na volta. Até chegar o vídeo, a foto. Se falhar, volta às
// fotos e tenta de novo com espera crescente (5 s, 10 s, 20 s... até 2 min). Só
// `autoplayMax` (padrão 8, CameraWidget::AUTOPLAY_MAX) ao vivo abertos por
// página: os excedentes ficam na foto e entram quando abrir uma vaga. Tocar no
// botão para desligar deixa o card na foto até tocar de novo.
// Sem framework de teste de JS: o request spec confere os data-attributes e o
// comportamento foi conferido à mão no navegador (docs/cameras.md).
const open = new Set() // controllers com ao vivo aberto (qualquer origem)
const waiting = new Set() // autoplay querendo abrir, sem vaga
const BACKOFF_MIN = 5000
const BACKOFF_MAX = 120000
const NO_VIDEO_MS = 12000
const WEBRTC_MS = 4000
const WEBRTC_SKIP_MS = 5 * 60 * 1000
const MSE_CODECS = ["avc1.640029", "avc1.64002A", "avc1.640033", "hvc1.1.6.L153.B0", "mp4a.40.2", "mp4a.40.5", "flac", "opus"]
const MAX_QUEUE = 60
let webrtcFailedAt = 0

function freeSlot() {
  for (const c of [...waiting]) { waiting.delete(c); c.sync() }
}

function withPb(url, pb) {
  if (!pb) return url
  return `${url}${url.includes("?") ? "&" : "?"}pb=${encodeURIComponent(pb)}`
}

export default class extends Controller {
  static targets = ["img", "video", "status", "liveButton", "talkButton"]
  static values = { snapshot: String, webrtc: String, mse: String, hls: String, interval: Number, micDenied: String,
                    talkHome: String, autoplay: Boolean, autoplayMax: { type: Number, default: 8 } }

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

  get active() { return !!(this.pc || this.ws || this.hlsOn) }

  sync() {
    if (!this.element.isConnected) return
    const want = this.autoplayValue && this.inView && !document.hidden && !this.userOff
    if (!want) {
      waiting.delete(this)
      if (this.active && this.auto) this.stopLive()
      return
    }
    if (this.active || this.retryTimer) return
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
    this.userOff = this.active
    clearTimeout(this.retryTimer)
    this.retryTimer = null
    this.active ? this.stopLive() : this.startLive()
  }

  // Reprodução do DVR (pb = nome do stream) ou, com null, de volta ao ao vivo.
  source(pb) {
    this.pb = pb || null
    this.userOff = false
    clearTimeout(this.retryTimer)
    this.retryTimer = null
    this.stopLive()
    this.startLive()
  }

  startLive(auto = false) {
    this.auto = auto
    this.playing = false
    this.session = (this.session || 0) + 1
    open.add(this)
    if (this.hasLiveButtonTarget) this.liveButtonTarget.setAttribute("aria-pressed", "true")
    // Sem vídeo em NO_VIDEO_MS por nenhum caminho: conta como falha (volta às fotos e tenta depois).
    clearTimeout(this.noVideo)
    const session = this.session
    this.noVideo = setTimeout(() => { if (this.session === session && !this.playing) this.liveFailed() }, NO_VIDEO_MS)
    const skip = !this.mic && Date.now() - webrtcFailedAt < WEBRTC_SKIP_MS
    if (skip && this.hasMseValue) this.startMse(session)
    else this.startWebrtc(session)
  }

  async startWebrtc(session) {
    const pc = (this.pc = new RTCPeerConnection())
    pc.addTransceiver("video", { direction: "recvonly" })
    // ondaC2 (C10): com o microfone ligado (Falar), o áudio vai para o alto-falante da câmera (go2rtc).
    const mic = this.mic?.getAudioTracks()[0]
    mic ? pc.addTransceiver(mic, { direction: "sendrecv", streams: [this.mic] }) : pc.addTransceiver("audio", { direction: "recvonly" })
    pc.ontrack = (e) => {
      if (e.track.kind !== "video" || this.pc !== pc) return
      this.videoTarget.srcObject = e.streams[0] || new MediaStream([e.track])
      this.played()
    }
    pc.onconnectionstatechange = () => { if (this.pc === pc && pc.connectionState === "failed") this.webrtcFailed(session) }
    // Fora de casa a mídia da 8555 não chega: em WEBRTC_MS sem vídeo, o MSE pelo Rails.
    this.webrtcTimer = setTimeout(() => { if (this.pc === pc && !this.playing) this.webrtcFailed(session) }, WEBRTC_MS)
    try {
      await pc.setLocalDescription(await pc.createOffer())
      await this.iceGathered(pc)
      const res = await fetch(withPb(this.webrtcValue, this.pb), {
        method: "POST", body: pc.localDescription.sdp,
        headers: { "Content-Type": "application/sdp", "X-CSRF-Token": document.querySelector("meta[name=csrf-token]")?.content }
      })
      if (!res.ok) throw new Error(res.status)
      await pc.setRemoteDescription({ type: "answer", sdp: await res.text() })
    } catch {
      if (this.pc === pc) this.liveFailed()
    }
  }

  webrtcFailed(session) {
    if (this.session !== session || this.playing) return
    clearTimeout(this.webrtcTimer)
    this.pc?.close()
    this.pc = null
    this.videoTarget.srcObject = null
    if (!this.hasMseValue) return this.liveFailed()
    webrtcFailedAt = Date.now()
    // Falar precisa do WebRTC (o microfone vai por ele): fora de casa, avisa e segue só com o vídeo.
    if (this.mic) { this.releaseMic(); this.status(this.talkHomeValue) }
    this.startMse(session)
  }

  // MSE do go2rtc por WebSocket, através do Rails (mesmo protocolo do video-rtc.js do go2rtc).
  startMse(session) {
    const MS = window.ManagedMediaSource || window.MediaSource
    if (!MS) return this.startHls(session)
    // O MSE ganha o próprio prazo (WebSocket + o go2rtc abrir a câmera).
    clearTimeout(this.noVideo)
    this.noVideo = setTimeout(() => { if (this.session === session && !this.playing) this.liveFailed() }, NO_VIDEO_MS)
    const video = this.videoTarget
    const ms = new MS()
    if (window.ManagedMediaSource && MS === window.ManagedMediaSource) {
      video.disableRemotePlayback = true
      video.srcObject = ms
    } else {
      video.src = URL.createObjectURL(ms)
    }
    ms.addEventListener("sourceopen", () => {
      if (this.session !== session) return
      if (video.src.startsWith("blob:")) URL.revokeObjectURL(video.src)
      const url = new URL(withPb(this.mseValue, this.pb), window.location.href)
      url.protocol = url.protocol === "https:" ? "wss:" : "ws:"
      const ws = (this.ws = new WebSocket(url))
      ws.binaryType = "arraybuffer"
      let sb = null
      const queue = []
      ws.onopen = () => {
        const codecs = MSE_CODECS.filter((c) => MS.isTypeSupported(`video/mp4; codecs="${c}"`)).join()
        ws.send(JSON.stringify({ type: "mse", value: codecs }))
      }
      ws.onmessage = (ev) => {
        if (this.ws !== ws) return
        if (typeof ev.data === "string") {
          const msg = JSON.parse(ev.data)
          if (msg.type === "mse") {
            try {
              sb = ms.addSourceBuffer(msg.value)
              sb.mode = "segments"
              sb.addEventListener("updateend", () => {
                if (!sb.updating && queue.length) this.append(sb, queue.shift())
                this.trim(sb)
              })
            } catch { this.liveFailed() }
          } else if (msg.type === "error") this.liveFailed()
          return
        }
        if (!sb) return
        if (sb.updating || queue.length) {
          queue.push(ev.data)
          if (queue.length > MAX_QUEUE) queue.splice(0, queue.length - MAX_QUEUE)
        } else this.append(sb, ev.data)
      }
      ws.onclose = () => {
        if (this.ws !== ws) return
        // Fim do tempo máximo do proxy com o vídeo tocando: abre de novo na hora.
        this.playing ? this.restart() : this.liveFailed()
      }
    }, { once: true })
    video.onloadeddata = () => { if (this.session === session) this.played() }
    video.play().catch(() => {})
  }

  append(sb, data) {
    try { sb.appendBuffer(data) } catch { this.liveFailed() }
  }

  // Fica perto do vivo (no máximo 2,5 s atrás) e o buffer não passa de ~15 s.
  trim(sb) {
    const video = this.videoTarget
    if (!sb.buffered.length || sb.updating) return
    const end = sb.buffered.end(sb.buffered.length - 1)
    const start = sb.buffered.start(0)
    if (end - video.currentTime > 2.5) video.currentTime = end - 0.5
    if (end - start > 15) { try { sb.remove(start, end - 10) } catch { /* segue */ } }
    if (video.paused) video.play().catch(() => {})
  }

  // HLS (Safari sem MSE): o link assinado vem do Rails e o <video> toca sozinho.
  async startHls(session) {
    const video = this.videoTarget
    if (!this.hasHlsValue || !video.canPlayType("application/vnd.apple.mpegurl")) return this.liveFailed()
    try {
      const res = await fetch(withPb(this.hlsValue, this.pb), { headers: { Accept: "application/json" } })
      if (!res.ok) throw new Error(res.status)
      const { url } = await res.json()
      if (this.session !== session) return
      this.hlsOn = true
      video.onloadeddata = () => { if (this.session === session) this.played() }
      video.src = url
      video.play().catch(() => {})
    } catch {
      if (this.session === session) this.liveFailed()
    }
  }

  played() {
    clearTimeout(this.webrtcTimer)
    clearTimeout(this.noVideo)
    this.playing = true
    this.backoff = 0
    this.show(this.videoTarget)
    this.dispatch("playing", { detail: { pb: this.pb } })
  }

  restart() {
    const auto = this.auto
    this.stopLive()
    this.startLive(auto)
  }

  // Falar (áudio de duas vias): liga o microfone e refaz o ao vivo mandando o áudio.
  async talk() {
    if (this.mic) {
      this.releaseMic()
      if (this.active) { this.stopLive(); this.startLive() }
      return
    }
    try {
      this.mic = await navigator.mediaDevices.getUserMedia({ audio: { echoCancellation: true, noiseSuppression: true } })
    } catch {
      this.status(this.micDeniedValue)
      return
    }
    this.talkButtonTarget.setAttribute("aria-pressed", "true")
    if (this.active) this.stopLive()
    this.startLive()
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
    if (!this.active && !open.has(this)) return
    this.session = (this.session || 0) + 1
    clearTimeout(this.noVideo)
    clearTimeout(this.webrtcTimer)
    this.pc?.close()
    this.pc = null
    const ws = this.ws
    this.ws = null
    ws?.close()
    this.hlsOn = false
    this.auto = false
    this.playing = false
    if (open.delete(this)) freeSlot()
    const video = this.videoTarget
    video.onloadeddata = null
    video.srcObject = null
    if (video.getAttribute("src")) { video.removeAttribute("src"); video.load() }
    video.hidden = true
    if (this.hasLiveButtonTarget) this.liveButtonTarget.setAttribute("aria-pressed", "false")
    this.refresh()
  }

  // Tela cheia do card (botão ou tecla F na tela da câmera).
  fullscreen() {
    if (document.fullscreenElement) document.exitFullscreen()
    else this.element.requestFullscreen?.().catch(() => {})
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

  // Aviso fora do quadro (microfone negado, falar só em casa), quando a tela tem onde mostrar.
  status(text) {
    // O aviso pode ficar logo depois do card (fora do controller), como na página do ponto.
    const el = this.hasStatusTarget ? this.statusTarget : this.element.parentElement?.querySelector(":scope > [data-camera-target='status']")
    if (!el || !text) return
    el.textContent = text
    el.hidden = false
  }
}
