module Ai
  module Providers
    # Adaptador do Claude. Saída estruturada por JSON schema; thinking
    # adaptativo + effort só quando pedido (e nunca no Haiku, que rejeita).
    class Anthropic
      Result = Data.define(:data, :usage)

      def initialize(config)
        @config = config
      end

      def complete(model:, system:, user:, schema:, max_tokens:, timeout:, effort: nil)
        params = {
          model: model,
          max_tokens: max_tokens,
          system_: [ { type: "text", text: system, cache_control: { type: "ephemeral" } } ],
          messages: [ { role: "user", content: user } ],
          output_config: { format: { type: "json_schema", schema: schema } },
          # Usuário olhando a tela: sem retentativa, teto curto.
          request_options: { timeout: timeout, max_retries: 0 }
        }
        if effort.present? && !model.to_s.include?("haiku")
          params[:thinking] = { type: "adaptive" }
          params[:output_config][:effort] = effort
        end

        message = client.messages.create(**params)
        Result.new(data: parse(message), usage: { input: message.usage&.input_tokens.to_i, output: message.usage&.output_tokens.to_i })
      rescue ::Anthropic::Errors::APITimeoutError
        raise Ai::Client::TransientError, "A IA demorou demais para responder (mais de #{timeout}s)."
      rescue ::Anthropic::Errors::Error => e
        # O e.message traz o corpo cru da resposta: só no log.
        Rails.logger.warn("[ai] anthropic #{e.class}: #{e.message.to_s.first(500)}")
        transient = e.is_a?(::Anthropic::Errors::APIConnectionError) ||
                    (e.respond_to?(:status) && (e.status.to_i == 429 || e.status.to_i >= 500))
        raise (transient ? Ai::Client::TransientError : Ai::Client::Error), "A IA não conseguiu responder agora. Tente de novo."
      end

      private

      def parse(message)
        json = message.content.filter_map { |b| b.text if b.respond_to?(:text) }.join
        raise Ai::Client::Error, "A IA não devolveu resposta. Tente de novo." if json.blank?

        JSON.parse(json, symbolize_names: true)
      rescue JSON::ParserError => e
        Rails.logger.warn("[ai] anthropic JSON inválido: #{e.message}")
        raise Ai::Client::Error, "A IA respondeu num formato inesperado. Tente de novo."
      end

      def client
        @client ||= ::Anthropic::Client.new(api_key: ENV.fetch(@config[:env]))
      end
    end
  end
end
