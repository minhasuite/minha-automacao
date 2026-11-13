import { Controller } from "@hotwired/stimulus"
import { startWav } from "controllers/voice/wav_recorder"

// Assistente de voz (Pacote 3): grava pelo microfone (Web Audio, em WAV; exige
// https ou localhost) ou manda o texto digitado para /assistente, mostra o
// que entendeu e a resposta, e toca a fala quando o servidor gera (TTS).
export default class extends Controller {
  static targets = ["dialog", "mic", "status", "text", "log", "audio", "offline"]
  static values = { url: String, site: String, texts: Object, statusUrl: String }

  t(key) { return this.textsValue[key] || key }

  open() {
    this.dialogTarget.showModal()
    if (!navigator.mediaDevices?.getUserMedia) this.statusTarget.textContent = this.t("https")
    this.checkStatus()
  }

  // voz-offline: sem internet, o selo "Modo offline" aparece (a casa entende só os comandos locais).
  async checkStatus() {
    if (!this.statusUrlValue) return
    try {
      const url = new URL(this.statusUrlValue, window.location.origin)
      url.searchParams.set("site_id", this.siteValue)
      const res = await fetch(url, { headers: { Accept: "application/json" } })
      if (res.ok) this.showOffline((await res.json()).offline)
    } catch (_) {
      this.showOffline(true)
    }
  }

  showOffline(on) {
    if (this.hasOfflineTarget) this.offlineTarget.hidden = !on
  }

  close() {
    if (this.recording) this.stop()
    this.dialogTarget.close()
  }

  // ondaB1 (B6): grava WAV PCM 16 kHz mono (vale para a voz da nuvem e para o Wyoming/Whisper local).
  async toggle() {
    if (this.recording) return this.stop()
    try {
      this.recording = await startWav()
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
    const body = new FormData()
    body.append("audio", rec.stop(), "fala.wav")
    this.post(body)
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
      if ("offline" in data) this.showOffline(data.offline)
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
