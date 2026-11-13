module Cameras
  # "Falar" gravado (ondaC2 C10; card do painel em visao-entrega): o áudio que o app ou o navegador
  # gravou vira anexo de 1 dia e a câmera toca pelo go2rtc (`play_media` → `ffmpeg:<url>#audio=pcma`).
  # Antes de guardar, tudo vira WAV PCM (o WAV do app passa direto; m4a do iPhone/Safari e
  # webm/opus do Chrome passam pelo ffmpeg do servidor, o mesmo do Wyoming). Sem ffmpeg aqui, vai
  # o original (o ffmpeg do go2rtc também lê). Quem chama confere o papel x risco.
  module Talk
    MAX = 5.megabytes

    class TooBig < StandardError; end

    module_function

    def call(point, bytes, media_type, source:)
      raise TooBig if bytes.bytesize > MAX

      bytes, media_type = wav(bytes, media_type)
      _blob, path = Ai::Audio.store(bytes, media_type, "falar-#{Time.current.to_i}")
      Points::Command.call(point, "play_media", MediaSources.public_url(path), source: source)
    end

    def wav(bytes, media_type)
      [ Wyoming.wav(*Wyoming.pcm_of(bytes, media_type)), "audio/wav" ]
    rescue Wyoming::Error
      [ bytes, media_type.presence || "audio/mp4" ]
    end
  end
end
