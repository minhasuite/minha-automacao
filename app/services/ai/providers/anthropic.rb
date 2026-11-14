module Ai
  module Providers
    # Claude pela gem oficial `anthropic`. Saída estruturada por
    # `output_config.format` (JSON schema); thinking adaptativo + effort só
    # quando pedido (e nunca no Haiku). Sem temperatura: os modelos atuais
    # (Sonnet/Haiku 5.5) recusam valor fora do padrão. Eles pensam por padrão
    # e o raciocínio conta no `max_tokens`: corte vira TruncatedError (o
    # Ai::Request tenta com o dobro); 429/5xx/529 viram TransientError com o
    # status e o tipo no `detail` (vai para o AiCall, sem o corpo).
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
          # A nova tentativa (com espera) é do Ai::Request, igual para todos os provedores.
          request_options: { timeout: timeout, max_retries: 0 }
        }
        params[:output_config] = { format: { type: "json_schema", schema: schema } } if schema
        if effort.present? && !model.to_s.include?("haiku")
          params[:thinking] = { type: "adaptive" }
          (params[:output_config] ||= {})[:effort] = effort
        end

        message = client.messages.create(**params)
        usage = { input: message.usage&.input_tokens.to_i, output: message.usage&.output_tokens.to_i }
        stop = message.stop_reason.to_s
        raise Ai::Client::Error.new("A IA recusou o pedido.", detail: "stop_reason refusal", usage: usage) if stop == "refusal"
        # Cortada no limite: o raciocínio (Haiku/Sonnet 5.5 pensam por padrão) também conta no max_tokens,
        # e o JSON da saída estruturada sai pela metade. O Ai::Request tenta com o dobro.
        if stop == "max_tokens"
          raise Ai::Client::TruncatedError.new("A IA respondeu num formato inesperado. Tente de novo.",
                                               detail: "stop_reason max_tokens (limite #{max_tokens}, saída #{usage[:output]})", usage: usage)
        end

        text = message.content.filter_map { |b| b.text if b.respond_to?(:text) }.join
        result(text, schema, usage[:input], usage[:output])
      rescue ::Anthropic::Errors::APITimeoutError
        raise Ai::Client::TransientError.new("A IA demorou demais para responder (mais de #{timeout}s).", detail: "tempo esgotado (#{timeout}s)")
      rescue ::Anthropic::Errors::APIConnectionError => e
        Rails.logger.warn("[ai] anthropic #{e.class}: #{e.message.to_s.first(300)}")
        raise Ai::Client::TransientError.new("Falha de rede ao chamar a IA. Tente de novo.", detail: "conexão (#{e.class.name.demodulize})")
      rescue ::Anthropic::Errors::Error => e
        # O e.message traz o corpo cru da resposta: só no log. No AiCall, só status e tipo do erro.
        Rails.logger.warn("[ai] anthropic #{e.class}: #{e.message.to_s.first(500)}")
        status = e.respond_to?(:status) ? e.status.to_i : 0
        kind = (e.type if e.respond_to?(:type)).to_s.presence || e.class.name.demodulize
        transient = status == 429 || status >= 500 # 529 = overloaded_error
        detail = "HTTP #{status} #{kind}".strip
        raise (transient ? Ai::Client::TransientError : Ai::Client::Error).new(
          status.in?([ 401, 403 ]) ? "A chave do provedor foi recusada (#{status})." : "A IA não conseguiu responder agora. Tente de novo.",
          detail: detail, retry_after: retry_after(e)
        )
      end

      private

      def client
        @client ||= ::Anthropic::Client.new(api_key: @api_key)
      end

      # Segundos do cabeçalho retry-after (429/529), quando vier.
      def retry_after(error)
        h = error.respond_to?(:headers) ? error.headers : nil
        v = h && (h["retry-after"] || h["Retry-After"])
        Float(v.to_s, exception: false)
      rescue StandardError
        nil
      end
    end
  end
end
