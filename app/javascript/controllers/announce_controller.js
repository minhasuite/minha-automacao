import { Controller } from "@hotwired/stimulus"

// "Falar na Alexa" (widget announce): manda o texto ou grava a voz e manda o
// áudio para Alexa::Talk (POST locais/:id/falar-na-alexa). O microfone só
// aparece em contexto seguro (https/localhost): o navegador não grava por IP.
export default class extends Controller {
  static targets = ["text", "echo", "mic", "send", "status"]
  static values = { url: String, max: Number, sent: String, recording: String, micDenied: String }

  connect() {
    if (this.hasMicTarget && window.isSecureContext && navigator.mediaDevices?.getUserMedia && window.MediaRecorder) {
      this.micTarget.hidden = false
    }
  }

  disconnect() { this.stop(true) }

  send(event) {
    event.preventDefault()
    const text = this.textTarget.value.trim()
    if (!text) return this.textTarget.focus()
    const body = this.form()
    body.append("text", text)
    this.post(body, () => { this.textTarget.value = "" })
  }

  async record() {
    if (this.recorder) return this.stop()
    let stream
    try {
      stream = await navigator.mediaDevices.getUserMedia({ audio: true })
    } catch {
      return this.say(this.micDeniedValue, true)
    }
    const chunks = []
    this.recorder = new MediaRecorder(stream)
    this.recorder.ondataavailable = (e) => e.data.size && chunks.push(e.data)
    this.recorder.onstop = () => {
      stream.getTracks().forEach((t) => t.stop())
      const cancelled = this.cancelled
      this.recorder = null
      this.cancelled = false
      this.micTarget.classList.remove("ss-btn-danger")
      this.micTarget.setAttribute("aria-pressed", "false")
      if (cancelled || !chunks.length) return
      const type = chunks[0].type || "audio/webm"
      const body = this.form()
      body.append("audio", new Blob(chunks, { type }), `fala.${type.includes("mp4") ? "m4a" : "webm"}`)
      this.post(body)
    }
    this.recorder.start()
    this.micTarget.classList.add("ss-btn-danger")
    this.micTarget.setAttribute("aria-pressed", "true")
    this.say(this.recordingValue)
    this.timer = setTimeout(() => this.stop(), this.maxValue * 1000)
  }

  stop(cancel = false) {
    clearTimeout(this.timer)
    if (!this.recorder) return
    this.cancelled = cancel
    this.recorder.stop()
  }

  form() {
    const body = new FormData()
    body.append("targets", this.hasEchoTarget ? this.echoTarget.value : "all")
    return body
  }

  async post(body, done) {
    this.sendTarget.disabled = true
    try {
      const token = document.querySelector("meta[name=csrf-token]")?.content
      const res = await fetch(this.urlValue, { method: "POST", body, headers: { "X-CSRF-Token": token, Accept: "application/json" } })
      const json = await res.json().catch(() => ({}))
      if (!res.ok || json.ok === false) return this.say(json.error || res.statusText, true)
      this.say(this.sentValue)
      done?.()
    } catch (e) {
      this.say(e.message, true)
    } finally {
      this.sendTarget.disabled = false
    }
  }

  say(text, error = false) {
    this.statusTarget.textContent = text
    this.statusTarget.classList.toggle("is-error", error)
  }
}
