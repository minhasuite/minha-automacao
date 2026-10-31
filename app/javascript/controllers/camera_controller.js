import { Controller } from "@hotwired/stimulus"

// Widget de câmera: quadro a cada N segundos (só com a aba visível) e "Ao vivo"
// por WebRTC. A oferta vai ao Rails, que confere o papel e repassa ao go2rtc.
export default class extends Controller {
  static targets = ["img", "video", "status", "liveButton"]
  static values = { snapshot: String, webrtc: String, interval: Number }

  connect() {
    this.imgTarget.onload = () => this.show(this.imgTarget)
    this.imgTarget.onerror = () => this.offline("Sem imagem da câmera agora. Tentando de novo…")
    this.refresh()
    this.timer = setInterval(() => this.refresh(), this.intervalValue * 1000)
  }

  disconnect() {
    clearInterval(this.timer)
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
    this.status("Conectando…")
    pc.addTransceiver("video", { direction: "recvonly" })
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

  iceGathered(pc) {
    if (pc.iceGatheringState === "complete") return Promise.resolve()
    return new Promise((resolve) => {
      setTimeout(resolve, 2000)
      pc.onicegatheringstatechange = () => { if (pc.iceGatheringState === "complete") resolve() }
    })
  }

  liveFailed() {
    this.stopLive()
    this.status("Ao vivo indisponível; mostrando quadros")
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
    this.statusTarget.hidden = true
    this.element.dataset.state = "on"
  }

  offline(text) {
    if (this.pc) return
    this.imgTarget.hidden = true
    this.element.dataset.state = "offline"
    this.status(text)
  }

  status(text) {
    this.statusTarget.textContent = text
    this.statusTarget.hidden = false
  }
}
