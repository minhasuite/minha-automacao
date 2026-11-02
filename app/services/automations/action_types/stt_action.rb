module Automations
  module ActionTypes
    # "Transcrever áudio" (Lote 5, G14; o STT do HA): áudio por URL https ou
    # anexo do sistema (a fala da ação "Gerar fala", um áudio gravado), com o
    # provedor de voz da instalação. Resposta: {text, provider, model}; no texto
    # `{{ fala.text }}`, e dá para mandar para "Pedir à IA".
    class SttAction < Base
      describe key: "stt", label: "Transcrever áudio", defaults: { "language" => "pt", "response_variable" => "fala" },
               fields: [ f("audio", :template, "Áudio (URL https ou anexo, texto com {{ }})", required: true, en: "Audio (https URL or attachment, text with {{ }})", es: "Audio (URL https o adjunto, texto con {{ }})"),
                         f("language", :text, "Idioma (ex.: pt)", en: "Language (e.g. en)", es: "Idioma (ej.: es)"),
                         f("provider", :select, "Provedor (vazio = o padrão)", en: "Provider (empty = default)", es: "Proveedor (vacío = el predeterminado)", options: -> { Ai.choices(:stt) }),
                         f("model", :text, "Modelo (vazio = o do provedor)", en: "Model (empty = provider's default)", es: "Modelo (vacío = el del proveedor)") ]
      returns "{text, provider, model}"
      texts en: { label: "Transcribe audio" }, es: { label: "Transcribir audio" }

      def self.call(e, _path, node)
        url = e.ctx.render(node["audio"]).strip
        return [ label, "simulated", "Não transcrito (simulação): #{url.truncate(60)}" ] if e.dry_run?

        audio, type = Ai::Audio.fetch(url)
        res = Ai::Audio.transcribe(tenant: e.ctx.site.tenant, site: e.ctx.site, automation: e.run.automation, audio: audio, media_type: type,
                                   language: node["language"], provider: node["provider"], model: node["model"])
        text = res.data.to_s.dup.force_encoding(Encoding::UTF_8).scrub
        respond(e, node, { "text" => text, "provider" => res.provider, "model" => res.model })
        [ label, "ok", "#{Ai.provider(res.provider)&.label} · #{res.model} · #{text.size} caracteres" ]
      rescue Ai::Client::Error, ArgumentError, SafeHttp::Error, ActiveStorage::FileNotFoundError => ex
        raise Engine::Failure, "Voz: #{ex.message}"
      end
    end
  end
end
