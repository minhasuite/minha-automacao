module Ai
  module Providers
    # Voz local (Lote 5, G14): servidor da casa compatível com a API de voz da
    # OpenAI, como o faster-whisper-server/speaches (Whisper) e o
    # openedai-speech (Piper). Só voz: não entra na escolha de texto.
    class LocalAudio < Base
      include OpenaiAudio

      describe key: "local_audio", label: "Voz local (Whisper / Piper)", default_model: "whisper-1",
               models: %w[whisper-1 Systran/faster-whisper-small], base_url: "http://localhost:8000/v1", custom_url: true, key_required: false,
               capabilities: %i[stt tts], stt_model: "whisper-1", tts_model: "tts-1", tts_voice: "alloy",
               hint: "Servidor compatível com /v1/audio (faster-whisper-server, openedai-speech). Libere o IP em Configurações → Sistema → " \
                     "Saída HTTP. O modelo daqui vale para a transcrição."
    end
  end
end
