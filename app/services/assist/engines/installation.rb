module Assist
  module Engines
    # Voz da instalação (Configurações → IA): o provedor com `stt`/`tts`
    # (OpenAI, Gemini, Voz local...), com a mesma conta, limite e registro.
    class Installation < Base
      describe key: "installation", label: "IA da instalação", kinds: %i[stt tts],
               fields: [ [ "provider", :provider ], [ "voice", :text ] ],
               hint: "Usa o provedor de voz de Configurações → IA (vazio = o padrão)."
      texts en: { label: "Installation AI", hint: "Uses the voice provider from Settings → AI (empty = the default)." },
            es: { label: "IA de la instalación", hint: "Usa el proveedor de voz de Configuración → IA (vacío = el predeterminado)." }

      def self.transcribe(cfg, site:, audio:, media_type:, language:)
        Assist.transcribe(site: site, audio: audio, media_type: media_type, language: language, provider: cfg["provider"])
      end

      def self.speak(cfg, site:, text:, language:)
        Ai::Audio.speak(tenant: site.tenant, site: site, text: text, voice: cfg["voice"], provider: cfg["provider"], source: "voz").data
      end
    end
  end
end
