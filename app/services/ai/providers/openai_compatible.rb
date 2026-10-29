require "net/http"

module Ai
  module Providers
    # Adaptador `/chat/completions` (OpenAI). Net::HTTP direto: um POST JSON
    # não justifica SDK. Traduz bloco de imagem do formato Anthropic para
    # `image_url` com data URI.
    class OpenaiCompatible
      Result = Data.define(:data, :usage)

      def initialize(name, config)
        @name = name
        @config = config
      end

      def complete(model:, system:, user:, schema:, max_tokens:, timeout:, effort: nil)
        body = {
          model: model,
          messages: [ { role: "system", content: system }, { role: "user", content: translate(user) } ],
          response_format: { type: "json_schema", json_schema: { name: "resposta", strict: true, schema: schema } },
          max_completion_tokens: max_tokens
        }
        body[:reasoning_effort] = effort if effort.present?
        json = post(body, timeout)
        text = json.dig("choices", 0, "message", "content")
        raise Ai::Client::Error, "A IA não devolveu resposta. Tente de novo." if text.blank?

        usage = json["usage"] || {}
        Result.new(data: JSON.parse(text, symbolize_names: true),
                   usage: { input: usage["prompt_tokens"].to_i, output: usage["completion_tokens"].to_i })
      rescue JSON::ParserError => e
        Rails.logger.warn("[ai] #{@name} JSON inválido: #{e.message}")
        raise Ai::Client::Error, "A IA respondeu num formato inesperado. Tente de novo."
      end

      private

      def translate(user)
        return user if user.is_a?(String)

        Array(user).map do |block|
          if block[:type].to_s == "image"
            src = block[:source]
            { type: "image_url", image_url: { url: "data:#{src[:media_type]};base64,#{src[:data]}" } }
          else
            { type: "text", text: block[:text] }
          end
        end
      end

      def post(body, timeout)
        uri = URI("#{@config.fetch(:base_url)}/chat/completions")
        req = Net::HTTP::Post.new(uri)
        req["Authorization"] = "Bearer #{ENV.fetch(@config.fetch(:env))}"
        req["Content-Type"] = "application/json"
        req.body = body.to_json
        res = Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 10, read_timeout: timeout) { |h| h.request(req) }
        unless res.is_a?(Net::HTTPSuccess)
          Rails.logger.warn("[ai] #{@name} HTTP #{res.code}: #{res.body.to_s.first(500)}")
          klass = res.code.to_i == 429 || res.code.to_i >= 500 ? Ai::Client::TransientError : Ai::Client::Error
          raise klass, "A IA não conseguiu responder agora (#{res.code}). Tente de novo."
        end

        JSON.parse(res.body)
      rescue Net::OpenTimeout, Net::ReadTimeout, SocketError, SystemCallError => e
        Rails.logger.warn("[ai] #{@name} rede: #{e.class}: #{e.message}")
        raise Ai::Client::TransientError, "Falha de rede ao chamar a IA. Tente de novo."
      end
    end
  end
end
