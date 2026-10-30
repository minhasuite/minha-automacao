module Automations
  module ActionTypes
    # "Pedir à IA" (Lote 2, `ai_task.generate_data` do HA): pedido em Liquid
    # (pontos, variáveis, gatilho), instruções de sistema, imagens (quadro das
    # câmeras agora, URL ou anexo), saída livre ou estruturada (campos ou JSON
    # schema), temperatura, limite de tokens e provedor/modelo opcionais. Usa a
    # IA da instalação (Ai::Request: chave do usuário, limite mensal, registro
    # de custo). Resposta: {data (texto ou os campos), provider, model, tokens,
    # cost}: `{{ ia.data }}`, `ia.data.anomalia` na expressão. O trace leva só
    # provedor, modelo e tokens, nunca o pedido nem a resposta.
    class AiTaskAction < Base
      FIELDS = [
        f("prompt", :prompt, "Pedido (texto com {{ }})", required: true), f("system", :prompt, "Instruções de sistema (opcional)"),
        f("cameras", :cameras, "Imagens: quadro destas câmeras agora"), f("image_urls", :template, "Ou imagens por URL ou anexo (uma por linha)"),
        f("output", :ai_output, "Saída estruturada: um campo por linha (nome: texto|número|inteiro|sim/não|lista descrição) ou JSON schema. Vazio = texto livre"),
        f("temperature", :number, "Temperatura (0 a 2; se o provedor aceitar)"), f("max_tokens", :number, "Limite de tokens da resposta"),
        f("provider", :select, "Provedor (vazio = o padrão)", options: -> { Ai.choices }), f("model", :text, "Modelo (vazio = o do provedor)")
      ].freeze

      describe key: "ai_task", label: "Pedir à IA", defaults: { "response_variable" => "ia" }, fields: FIELDS
      returns "{data (texto ou os campos), provider, model, tokens, cost}"

      def self.rules(node)
        msgs = []
        msgs << "temperatura de 0 a 2." if node["temperature"] && !(node["temperature"].is_a?(::Numeric) && node["temperature"].between?(0, 2))
        msgs << "limite de tokens de 1 a 8000." if node["max_tokens"] && !(node["max_tokens"].is_a?(Integer) && node["max_tokens"].between?(1, 8000))
        msgs
      end

      # Texto antes do pedido (o "Gerar dados por IA" põe o estado dos pontos aqui).
      def self.context(_e, _node) = nil

      def self.call(e, _path, node)
        title = label
        prompt = [ context(e, node), e.ctx.render(node["prompt"], limit: 20_000) ].compact.join("\n\n")
        return [ title, "simulated", "Não chamada (simulação). Pedido de #{prompt.size} caracteres." ] if e.dry_run?

        images, notes = Ai::Images.collect(e.ctx, node["cameras"], (e.ctx.render(node["image_urls"]) if node["image_urls"]))
        res = Ai::Request.call(tenant: e.ctx.site.tenant, site: e.ctx.site, automation: e.run.automation, source: "automacao",
                               prompt: prompt, system: (e.ctx.render(node["system"], limit: 20_000) if node["system"]), images: images,
                               schema: Ai::Output.schema(node["output"]), provider: node["provider"], model: node["model"],
                               temperature: node["temperature"], max_tokens: node["max_tokens"])
        respond(e, node, res.to_h)
        [ title, "ok", [ "#{Ai.provider(res.provider)&.label} · #{res.model} · #{res.tokens} tokens", ("#{images.size} imagem(ns)" if images.any?), *notes ].compact.join(" · ") ]
      rescue Ai::Client::Error, ArgumentError => ex
        raise Engine::Failure, "IA: #{ex.message}"
      end
    end
  end
end
