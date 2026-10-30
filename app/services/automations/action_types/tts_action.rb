module Automations
  module ActionTypes
    # "Gerar fala" (Lote 5, G14; o TTS do HA): texto Liquid → áudio do provedor
    # de voz, guardado como anexo com URL assinada que vale 1 dia. Resposta:
    # {url, content_type, bytes, provider, model}; use `{{ fala.url }}` no link
    # do aviso, em "Chamar HTTP" ou em "Transcrever áudio".
    class TtsAction < Base
      describe key: "tts", label: "Gerar fala", defaults: { "response_variable" => "fala" },
               fields: [ f("text", :template, "Texto (com {{ }})", required: true), f("voice", :text, "Voz (vazio = a do provedor)"),
                         f("provider", :select, "Provedor (vazio = o padrão)", options: -> { Ai.choices(:tts) }),
                         f("model", :text, "Modelo (vazio = o do provedor)") ]
      returns "{url, content_type, bytes, provider, model}"

      def self.call(e, _path, node)
        text = e.ctx.render(node["text"])
        return [ label, "simulated", "Não gerada (simulação): #{text.size} caracteres" ] if e.dry_run?

        res = Ai::Audio.speak(tenant: e.ctx.site.tenant, site: e.ctx.site, automation: e.run.automation, text: text, voice: node["voice"],
                              provider: node["provider"], model: node["model"])
        _blob, url = Ai::Audio.store(res.data[:data], res.data[:media_type], "fala-#{Time.current.to_i}")
        respond(e, node, { "url" => url, "content_type" => res.data[:media_type], "bytes" => res.data[:data].bytesize,
                           "provider" => res.provider, "model" => res.model })
        [ label, "ok", "#{Ai.provider(res.provider)&.label} · #{res.model} · #{res.data[:data].bytesize} bytes" ]
      rescue Ai::Client::Error => ex
        raise Engine::Failure, "Voz: #{ex.message}"
      end
    end
  end
end
