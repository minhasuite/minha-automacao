// Gravação do microfone em WAV PCM 16 kHz mono (ondaB1 B6; voz-offline): o
// formato que o Whisper local (Wyoming) aceita e que a nuvem também lê.
// Exige https ou localhost. start() → { stop(): Blob }.
export async function startWav() {
  const stream = await navigator.mediaDevices.getUserMedia({ audio: { channelCount: 1, echoCancellation: true, noiseSuppression: true } })
  const ctx = new AudioContext({ sampleRate: 16000 })
  const source = ctx.createMediaStreamSource(stream)
  const node = ctx.createScriptProcessor(4096, 1, 1)
  const samples = []
  node.onaudioprocess = (e) => samples.push(new Float32Array(e.inputBuffer.getChannelData(0)))
  source.connect(node)
  node.connect(ctx.destination)
  return {
    stop() {
      node.disconnect()
      source.disconnect()
      stream.getTracks().forEach((t) => t.stop())
      const rate = ctx.sampleRate
      ctx.close()
      return wav(samples, rate)
    }
  }
}

export function wav(chunks, rate) {
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
