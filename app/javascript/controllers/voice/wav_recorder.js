// Gravação do microfone em WAV PCM 16 kHz mono (ondaB1 B6; voz-offline): o
// formato que o Whisper local (Wyoming) aceita e que a nuvem também lê.
// Exige https ou localhost. startWav() → { stop(): Blob } (16 kHz, ou menos se o aparelho gravar abaixo).
export async function startWav() {
  // iPhone (pwa-ios): o AudioContext nasce e acorda (resume) ainda dentro do toque, antes de qualquer await;
  // criado depois do getUserMedia ele fica "suspended" e grava silêncio. Taxa do aparelho (o WebKit não
  // mistura microfone de 48 kHz com contexto de 16 kHz): a conversão para 16 kHz é no stop().
  const Ctx = window.AudioContext || window.webkitAudioContext
  const ctx = new Ctx()
  const resumed = ctx.resume().catch(() => {})
  let stream
  try {
    stream = await navigator.mediaDevices.getUserMedia({ audio: { channelCount: 1, echoCancellation: true, noiseSuppression: true } })
  } catch (e) {
    ctx.close()
    throw e
  }
  await resumed
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
      const to = Math.min(rate, RATE)
      return wav([resample(samples, rate, to)], to)
    }
  }
}

const RATE = 16000

// Média por janela (o bastante para voz) de `from` Hz para `to` Hz; mesma taxa = só junta os pedaços.
export function resample(chunks, from, to) {
  const length = chunks.reduce((n, c) => n + c.length, 0)
  const all = new Float32Array(length)
  let o = 0
  chunks.forEach((c) => { all.set(c, o); o += c.length })
  if (from <= to) return all
  const ratio = from / to
  const out = new Float32Array(Math.floor(length / ratio))
  for (let i = 0; i < out.length; i++) {
    const a = Math.floor(i * ratio), b = Math.min(length, Math.floor((i + 1) * ratio))
    let sum = 0
    for (let j = a; j < b; j++) sum += all[j]
    out[i] = b > a ? sum / (b - a) : 0
  }
  return out
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
