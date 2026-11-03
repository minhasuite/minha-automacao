module Assist
  module Engines
    # Servidor Wyoming na rede da casa (ondaB1, B6): Whisper/faster-whisper
    # (STT), Piper (TTS) e openWakeWord (palavra de ativação), como no HA.
    # Áudio de entrada em WAV PCM (o botão Falar já grava assim).
    class WyomingServer < Base
      HOST = /\A[a-zA-Z0-9][a-zA-Z0-9.-]{0,252}\z/

      describe key: "wyoming", label: "Wyoming (Whisper, Piper, openWakeWord)", kinds: %i[stt tts wake],
               fields: [ [ "host", :text ], [ "port", :number ], [ "model", :text, %i[stt] ], [ "voice", :text, %i[tts] ], [ "names", :text, %i[wake] ] ],
               hint: "Servidor Wyoming da rede (portas padrão: Whisper 10300, Piper 10200, openWakeWord 10400). Nada sai da casa."
      texts en: { label: "Wyoming (Whisper, Piper, openWakeWord)",
                  hint: "Wyoming server on the network (default ports: Whisper 10300, Piper 10200, openWakeWord 10400). Nothing leaves the house." },
            es: { label: "Wyoming (Whisper, Piper, openWakeWord)",
                  hint: "Servidor Wyoming de la red (puertos por defecto: Whisper 10300, Piper 10200, openWakeWord 10400). Nada sale de la casa." },
            "pt-BR" => { host: "endereço do servidor Wyoming inválido.", port: "porta de 1 a 65535." }
      texts en: { host: "invalid Wyoming server address.", port: "port from 1 to 65535." },
            es: { host: "dirección del servidor Wyoming no válida.", port: "puerto de 1 a 65535." }

      def self.check(cfg, _kind)
        port = cfg["port"].to_s
        [ (text(:host) unless cfg["host"].to_s.match?(HOST)), (text(:port) unless port.empty? || port.to_i.between?(1, 65_535)) ].compact
      end

      def self.port(cfg, kind) = cfg["port"].to_i.positive? ? cfg["port"].to_i : ::Wyoming::PORTS.fetch(kind)

      def self.transcribe(cfg, audio:, media_type:, language:, **)
        pcm, rate, width, channels = ::Wyoming.pcm_of(audio, media_type)
        ::Wyoming.transcribe(cfg["host"], port(cfg, :stt), pcm, language: language, model: cfg["model"], rate: rate, width: width, channels: channels)
      end

      def self.speak(cfg, text:, **) = ::Wyoming.synthesize(cfg["host"], port(cfg, :tts), text, voice: cfg["voice"])

      def self.detect(cfg, audio:, media_type: "audio/wav", **)
        pcm, rate, width, channels = ::Wyoming.pcm_of(audio, media_type)
        ::Wyoming.detect(cfg["host"], port(cfg, :wake), pcm, names: cfg["names"].to_s.split(/[,\s]+/).compact_blank, rate: rate, width: width, channels: channels)
      end
    end
  end
end
