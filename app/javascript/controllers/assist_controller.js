import { Controller } from "@hotwired/stimulus"

// Assistente de voz (Pacote 3): grava pelo microfone (MediaRecorder; exige
// https ou localhost) ou manda o texto digitado para /assistente, mostra o
// que entendeu e a resposta, e toca a fala quando o servidor gera (TTS).
export default class extends Controller {
  static targets = ["dialog", "mic", "status", "text", "log", "audio"]
  static values = { url: String, site: String }

  open() {
    this.dialogTarget.showModal()
    if (!navigator.mediaDevices?.getUserMedia) this.statusTarget.textContent = "Microfone só pelo endereço seguro (https). Escreva abaixo."
  }

  close() {
    this.stop()
    this.dialogTarget.close()
  }

  async toggle() {
    if (this.recorder?.state === "recording") return this.stop()
    try {
      const stream = await navigator.mediaDevices.getUserMedia({ audio: true })
      this.chunks = []
      this.recorder = new MediaRecorder(stream)
      this.recorder.ondataavailable = (e) => e.data.size && this.chunks.push(e.data)
      this.recorder.onstop = () => {
        stream.getTracks().forEach((t) => t.stop())
        const blob = new Blob(this.chunks, { type: this.recorder.mimeType || "audio/webm" })
        const body = new FormData()
        body.append("audio", blob, "fala.webm")
        this.post(body)
      }
      this.recorder.start()
      this.micTarget.setAttribute("aria-pressed", "true")
      this.statusTarget.textContent = "Ouvindo… toque de novo para enviar"
      this.timeout = setTimeout(() => this.stop(), 15000)
    } catch (_) {
      this.statusTarget.textContent = "Sem acesso ao microfone. Escreva abaixo."
    }
  }

  stop() {
    clearTimeout(this.timeout)
    if (this.recorder?.state === "recording") this.recorder.stop()
    this.micTarget.setAttribute("aria-pressed", "false")
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
    this.statusTarget.textContent = "Pensando…"
    try {
      const res = await fetch(this.urlValue, {
        method: "POST", body, headers: { Accept: "application/json", "X-CSRF-Token": document.querySelector("meta[name=csrf-token]")?.content }
      })
      const data = await res.json()
      if (!res.ok) throw new Error(data.error || "Falhou")
      this.add(data.heard, "dw-assist-me")
      this.add(data.text, "dw-assist-house")
      this.statusTarget.textContent = "Toque para falar"
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
