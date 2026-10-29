require "net/http"

module Ai
  module Providers
    # Adaptador do Gemini (`generateContent`, Net::HTTP direto como o da
    # OpenAI). Traduz os blocos do formato Anthropic (texto, imagem e PDF em
    # base64) para `parts` com `inlineData`. Saída por `responseJsonSchema`
    # (aceita JSON Schema, inclusive `additionalProperties`).
    #
    # Raciocínio: família 3.x usa `thinkingLevel` (não dá para desligar; sem
    # effort vai o mínimo que o modelo aceita); 2.5 usa `thinkingBudget`. O
    # pensamento sai do mesmo `maxOutputTokens`, então ele ganha folga.
    class Gemini
      Result = Data.define(:data, :usage)

      BASE_URL = "https://generativelanguage.googleapis.com/v1beta/models".freeze
      BUDGETS = { "low" => 1_024, "medium" => 8_192, "high" => 24_576 }.freeze

      def initialize(config)
        @config = config
      end

      def complete(model:, system:, user:, schema:, max_tokens:, timeout:, effort: nil)
        thinking, headroom = thinking_config(model.to_s, effort.presence)
        body = {
          systemInstruction: { parts: [ { text: system } ] },
          contents: [ { role: "user", parts: parts(user) } ],
          generationConfig: { maxOutputTokens: max_tokens + headroom, responseMimeType: "application/json",
                              responseJsonSchema: schema, thinkingConfig: thinking }
        }
        json = post(model, body, timeout)
        Result.new(data: parse(json), usage: usage(json))
      end

      private

      def thinking_config(model, effort)
        level = effort && (BUDGETS.key?(effort) ? effort : "high")
        if model.start_with?("gemini-2")
          budget = level ? BUDGETS[level] : (model.include?("pro") ? 128 : 0) # o Pro não desliga
          [ { thinkingBudget: budget }, budget ]
        else
          level ||= model.include?("pro") ? "low" : "minimal" # o Pro não tem minimal
          [ { thinkingLevel: level }, BUDGETS.fetch(level, 0) ]
        end
      end

      def parts(user)
        return [ { text: user } ] if user.is_a?(String)

        Array(user).map do |block|
          b = block.to_h.with_indifferent_access
          case b[:type].to_s
          when "image" then { inlineData: { mimeType: b.dig(:source, :media_type), data: b.dig(:source, :data) } }
          when "document" then { inlineData: { mimeType: "application/pdf", data: b.dig(:source, :data) } }
          else { text: b[:text].to_s }
          end
        end
      end

      def parse(json)
        candidate = json.dig("candidates", 0)
        text = Array(candidate&.dig("content", "parts")).reject { |p| p["thought"] }.filter_map { |p| p["text"] }.join
        if text.blank?
          Rails.logger.warn("[ai] gemini sem texto: finish=#{candidate&.dig('finishReason')} block=#{json.dig('promptFeedback', 'blockReason')}")
          raise Ai::Client::Error, "A IA não devolveu resposta. Tente de novo."
        end

        JSON.parse(text, symbolize_names: true)
      rescue JSON::ParserError => e
        Rails.logger.warn("[ai] gemini JSON inválido (finish=#{candidate&.dig('finishReason')}): #{e.message}")
        raise Ai::Client::Error, "A IA respondeu num formato inesperado. Tente de novo."
      end

      # Pensamento é cobrado como saída.
      def usage(json)
        meta = json["usageMetadata"] || {}
        { input: meta["promptTokenCount"].to_i, output: meta["candidatesTokenCount"].to_i + meta["thoughtsTokenCount"].to_i }
      end

      def post(model, body, timeout)
        uri = URI("#{BASE_URL}/#{model}:generateContent")
        req = Net::HTTP::Post.new(uri)
        req["x-goog-api-key"] = ENV.fetch(@config.fetch(:env))
        req["Content-Type"] = "application/json"
        req.body = body.to_json
        res = Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 10, read_timeout: timeout) { |h| h.request(req) }
        return JSON.parse(res.body) if res.is_a?(Net::HTTPSuccess)

        # O corpo do erro fica no log; para o cliente vai só a mensagem genérica.
        Rails.logger.warn("[ai] gemini #{model} HTTP #{res.code}: #{res.body.to_s.first(500)}")
        klass = res.code.to_i == 429 || res.code.to_i >= 500 ? Ai::Client::TransientError : Ai::Client::Error
        raise klass, "A IA não conseguiu responder agora (#{res.code}). Tente de novo."
      rescue Net::OpenTimeout, Net::ReadTimeout
        raise Ai::Client::TransientError, "A IA demorou demais para responder (mais de #{timeout}s)."
      rescue SocketError, SystemCallError, OpenSSL::SSL::SSLError => e
        Rails.logger.warn("[ai] gemini rede: #{e.class}: #{e.message}")
        raise Ai::Client::TransientError, "Falha de rede ao chamar a IA. Tente de novo."
      end
    end
  end
end
