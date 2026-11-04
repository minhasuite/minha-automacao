module Ai
  module Providers
    # Claude pela gem oficial `anthropic`. Saída estruturada por
    # `output_config.format` (JSON schema); thinking adaptativo + effort só
    # quando pedido (e nunca no Haiku). Sem temperatura: os modelos atuais
    # (Sonnet/Haiku 5.5) recusam valor fora do padrão.
    class Anthropic < Base
      describe key: "anthropic", label: "Anthropic (Claude)", default_model: "claude-sonnet-5-5",
               models: %w[claude-sonnet-5-5 claude-haiku-5-5 claude-opus-5-5], capabilities: %i[text image structured tools],
               hint: "Chave em console.anthropic.com → API keys. claude-haiku-5-5 é a opção barata."
      texts en: { label: "Anthropic (Claude)", hint: "Get a key at console.anthropic.com → API keys. claude-haiku-5-5 is the budget option." },
            es: { label: "Anthropic (Claude)", hint: "Clave en console.anthropic.com → API keys. claude-haiku-5-5 es la opción económica." }

      def complete(model:, system:, user:, schema:, max_tokens:, timeout:, effort: nil, temperature: nil) # rubocop:disable Lint/UnusedMethodArgument
        params = {
          model: model,
          max_tokens: max_tokens,
          system_: [ { type: "text", text: system, cache_control: { type: "ephemeral" } } ],
          messages: [ { role: "user", content: user } ],
          # Usuário olhando a tela: sem retentativa, teto curto.
          request_options: { timeout: timeout, max_retries: 0 }
        }
        params[:output_config] = { format: { type: "json_schema", schema: schema } } if schema
        if effort.present? && !model.to_s.include?("haiku")
          params[:thinking] = { type: "adaptive" }
          (params[:output_config] ||= {})[:effort] = effort
        end

        message = client.messages.create(**params)
        raise Ai::Client::Error, "A IA recusou o pedido." if message.stop_reason.to_s == "refusal"

        text = message.content.filter_map { |b| b.text if b.respond_to?(:text) }.join
        result(text, schema, message.usage&.input_tokens, message.usage&.output_tokens)
      rescue ::Anthropic::Errors::APITimeoutError
        raise Ai::Client::TransientError, "A IA demorou demais para responder (mais de #{timeout}s)."
      rescue ::Anthropic::Errors::Error => e
        # O e.message traz o corpo cru da resposta: só no log.
        Rails.logger.warn("[ai] anthropic #{e.class}: #{e.message.to_s.first(500)}")
        status = e.respond_to?(:status) ? e.status.to_i : 0
        transient = e.is_a?(::Anthropic::Errors::APIConnectionError) || status == 429 || status >= 500
        raise (transient ? Ai::Client::TransientError : Ai::Client::Error),
              status.in?([ 401, 403 ]) ? "A chave do provedor foi recusada (#{status})." : "A IA não conseguiu responder agora. Tente de novo."
      end

      private

      def client
        @client ||= ::Anthropic::Client.new(api_key: @api_key)
      end
    end
  end
end
