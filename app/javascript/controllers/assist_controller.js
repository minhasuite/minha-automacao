import { Controller } from "@hotwired/stimulus"

// Assistente de voz (Pacote 3): grava pelo microfone (Web Audio, em WAV; exige
// https ou localhost) ou manda o texto digitado para /assistente, mostra o
// que entendeu e a resposta, e toca a fala quando o servidor gera (TTS).
export default class extends Controller {
  static targets = ["dialog", "mic", "status", "text", "log", "audio"]
  static values = { url: String, site: String, texts: Object }

  t(key) { return this.textsValue[key] || key }

  open() {
    this.dialogTarget.showModal()
    if (!navigator.mediaDevices?.getUserMedia) this.statusTarget.textContent = this.t("https")
  }

  close() {
    if (this.recording) this.stop()
    this.dialogTarget.close()
  }

  // ondaB1 (B6): grava WAV PCM 16 kHz mono (vale para a voz da nuvem e para o Wyoming/Whisper local).
  async toggle() {
    if (this.recording) return this.stop()
    try {
      const stream = await navigator.mediaDevices.getUserMedia({ audio: { channelCount: 1, echoCancellation: true, noiseSuppression: true } })
      const ctx = new AudioContext({ sampleRate: 16000 })
      const source = ctx.createMediaStreamSource(stream)
      const node = ctx.createScriptProcessor(4096, 1, 1)
      this.samples = []
      node.onaudioprocess = (e) => this.samples.push(new Float32Array(e.inputBuffer.getChannelData(0)))
      source.connect(node)
      node.connect(ctx.destination)
      this.recording = { stream, ctx, node, source }
      this.micTarget.dataset.ssMicStateValue = "listening"
      this.statusTarget.textContent = this.t("listening")
      this.timeout = setTimeout(() => this.stop(), 15000)
    } catch (_) {
      this.statusTarget.textContent = this.t("no_mic")
    }
  }

  stop() {
    clearTimeout(this.timeout)
    this.micTarget.dataset.ssMicStateValue = "idle"
    const rec = this.recording
    if (!rec) return
    this.recording = null
    rec.node.disconnect()
    rec.source.disconnect()
    rec.stream.getTracks().forEach((t) => t.stop())
    const rate = rec.ctx.sampleRate
    rec.ctx.close()
    const body = new FormData()
    body.append("audio", this.wav(this.samples, rate), "fala.wav")
    this.post(body)
  }

  wav(chunks, rate) {
    const length = chunks.reduce((n, c) => n + c.length, 0)
    const view = new DataView(new ArrayBuffer(44 + length * 2))
    const text = (o, s) => [...s].forEach((ch, i) => view.setUint8(o + i, ch.charCodeAt(0)))
    text(0, "RIFF"); view.setUint32(4, 36 + length * 2, true); text(8, "WAVE"); text(12, "fmt ")
    view.setUint32(16, 16, true); view.setUint16(20, 1, true); view.setUint16(22, 1, true); view.setUint32(24, rate, true)
    view.setUint32(28, rate * 2, true); view.setUint16(32, 2, true); view.setUint16(34, 16, true); text(36, "data"); view.setUint32(40, length * 2, true)
    let o = 44
    chunks.forEach((c) => c.forEach((v) => { view.setInt16(o, Math.max(-1, Math.min(1, v)) * 0x7fff, true); o += 2 }))
    return new Blob([view], { type: "audio/wav" })
  }

  send(event) {
    event.preventDefault()
    const text = this.textTarget.value.trim()
    if (!text) return
    const body = new FormData()
    body.append("text", text)
    this.textTarget.value = ""
    this.post(body)
  }

  async post(body) {
    body.append("site_id", this.siteValue)
    body.append("speak", "1")
    if (this.conversation) body.append("conversation_id", this.conversation)
    this.statusTarget.textContent = this.t("thinking")
    try {
      const res = await fetch(this.urlValue, {
        method: "POST", body, headers: { Accept: "application/json", "X-CSRF-Token": document.querySelector("meta[name=csrf-token]")?.content }
      })
      const data = await res.json()
      if (!res.ok) throw new Error(data.error || this.t("failed"))
      this.conversation = data.conversation_id
      this.add(data.heard, "ss-bubble is-me")
      this.add(data.text, "ss-bubble whitespace-pre-line")
      this.statusTarget.textContent = this.t("idle")
      if (data.audio_url) { this.audioTarget.src = data.audio_url; this.audioTarget.play().catch(() => {}) }
    } catch (e) {
      this.statusTarget.textContent = e.message
    }
  }

  add(text, css) {
    if (!text) return
    const p = document.createElement("p")
    p.className = css
    p.textContent = text
    this.logTarget.append(p)
  }
}
