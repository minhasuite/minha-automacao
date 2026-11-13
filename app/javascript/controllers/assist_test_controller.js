import { Controller } from "@hotwired/stimulus"
import { startWav } from "controllers/voice/wav_recorder"

// Aba Testar do Assistente de voz (voz-offline): grava a fala em WAV, põe no
// campo de arquivo do formulário e envia (o servidor roda o pipeline e mostra
// o texto, a intenção e o tempo de cada etapa). Sem microfone: escreva.
export default class extends Controller {
  static targets = ["mic", "file", "status", "form"]
  static values = { texts: Object }

  t(key) { return this.textsValue[key] || key }

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
    const rec = this.recording
    if (!rec) return
    this.recording = null
    this.micTarget.dataset.ssMicStateValue = "processing"
    this.statusTarget.textContent = this.t("thinking")
    const files = new DataTransfer()
    files.items.add(new File([rec.stop()], "fala.wav", { type: "audio/wav" }))
    this.fileTarget.files = files.files
    this.formTarget.requestSubmit()
  }
}
