import { Controller } from "@hotwired/stimulus"

// Câmera (no Ss::CameraTileComponent da gem): quadro a cada N segundos (só com a
// aba visível) e "Ao vivo" por WebRTC. A oferta vai ao Rails, que confere o papel
// e repassa ao go2rtc. O desenho do estado é da gem (data-state: loading, stale
// com a idade do quadro, live, offline); aqui só se troca o data-state.
export default class extends Controller {
  static targets = ["img", "video", "status", "liveButton", "talkButton"]
  static values = { snapshot: String, webrtc: String, interval: Number, micDenied: String }

  connect() {
    this.imgTarget.onload = () => this.show(this.imgTarget)
    this.imgTarget.onerror = () => this.offline()
    this.retry = () => this.refresh()
    this.element.addEventListener("ss-camera:retry", this.retry)
    this.refresh()
    this.timer = setInterval(() => this.refresh(), this.intervalValue * 1000)
  }

  disconnect() {
    clearInterval(this.timer)
    this.element.removeEventListener("ss-camera:retry", this.retry)
    this.releaseMic()
    this.stopLive()
  }

  refresh() {
    if (document.hidden || this.pc) return
    this.imgTarget.src = `${this.snapshotValue}?t=${Date.now()}`
  }

  toggle() {
    this.pc ? this.stopLive() : this.startLive()
  }

  async startLive() {
    const pc = (this.pc = new RTCPeerConnection())
    this.liveButtonTarget.setAttribute("aria-pressed", "true")
    pc.addTransceiver("video", { direction: "recvonly" })
    // ondaC2 (C10): com o microfone ligado (Falar), o áudio vai para o alto-falante da câmera (go2rtc).
    const mic = this.mic?.getAudioTracks()[0]
    mic ? pc.addTransceiver(mic, { direction: "sendrecv", streams: [this.mic] }) : pc.addTransceiver("audio", { direction: "recvonly" })
    pc.ontrack = (e) => {
      if (e.track.kind !== "video") return
      this.videoTarget.srcObject = e.streams[0] || new MediaStream([e.track])
      this.show(this.videoTarget)
    }
    pc.onconnectionstatechange = () => { if (pc.connectionState === "failed") this.liveFailed() }
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
      this.liveFailed()
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
    this.stopLive()
    setTimeout(() => this.refresh(), 1500)
  }

  stopLive() {
    if (!this.pc) return
    this.pc.close()
    this.pc = null
    this.videoTarget.srcObject = null
    this.videoTarget.hidden = true
    if (this.hasLiveButtonTarget) this.liveButtonTarget.setAttribute("aria-pressed", "false")
    this.refresh()
  }

  show(el) {
    if (el === this.imgTarget && this.pc) return
    this.imgTarget.hidden = el !== this.imgTarget
    this.videoTarget.hidden = el !== this.videoTarget
    // Quadro novo: a idade volta a zero (o ss-camera conta de novo).
    if (el === this.imgTarget) this.element.dataset.ssCameraAgeValue = 0
    this.element.dataset.state = el === this.videoTarget ? "live" : "stale"
  }

  offline() {
    if (this.pc) return
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
