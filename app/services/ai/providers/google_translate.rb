module Ai
  module Providers
    # Google Tradutor (catalogo, o "google_translate" do HA): fala grátis e sem
    # chave pela voz do Google Tradutor (o mesmo endpoint que o HA usa). Só
    # voz (TTS), MP3; o "modelo" é o idioma (pt-BR, en, es…). Texto longo vai
    # em pedaços de até 200 caracteres, emendados.
    class GoogleTranslate < Base
      describe key: "google_translate", label: "Google Tradutor (fala grátis)", default_model: "pt-BR", models: %w[pt-BR pt-PT en en-GB es es-US fr de it],
               capabilities: %i[tts], key_required: false, tts_model: "pt-BR", tts_voice: "",
               hint: "Fala grátis, sem chave, pela voz do Google Tradutor. O modelo é o idioma da fala."
      texts en: { label: "Google Translate (free speech)", hint: "Free speech, no key, using the Google Translate voice. The model is the speech language." },
            es: { label: "Google Traductor (voz gratis)", hint: "Voz gratis, sin clave, con la voz del Traductor de Google. El modelo es el idioma de la voz." }

      URL = "https://translate.google.com/translate_tts".freeze
      CHUNK = 200

      def self.chunks(text)
        text.to_s.squish.scan(/.{1,#{CHUNK}}(?=\s|\z)|\S{#{CHUNK}}/o).map(&:strip).compact_blank
      end

      def speak(text:, model:, voice:, timeout:) # rubocop:disable Lint/UnusedMethodArgument
        parts = self.class.chunks(text)
        data = parts.each_with_index.map do |part, i|
          q = { ie: "UTF-8", q: part, tl: model.presence || "pt-BR", total: parts.size, idx: i, textlen: part.length, client: "tw-ob" }
          res = SafeHttp.get("#{URL}?#{q.to_query}", headers: { "User-Agent" => "Mozilla/5.0", "Referer" => "http://translate.google.com/" }, timeout: timeout)
          http_error!(res.status, res.body) if res.status >= 400
          res.body.b
        end.join
        { media_type: "audio/mpeg", data: data }
      rescue SafeHttp::Error => e
        raise Ai::Client::TransientError, "Google Tradutor: #{e.message}"
      end
    end
  end
end
