require "net/http"

module Ai
  module Providers
    # Interface comum de um provedor de IA (plugin de Ai::PROVIDERS).
    #
    #   describe key:, label:, default_model:, capabilities:, models:, env:,
    #            base_url:, custom_url:, key_required:, hint:
    #   new(api_key:, base_url:).complete(model:, system:, user:, schema:,
    #       max_tokens:, timeout:, effort: nil, temperature: nil) → Result
    #
    # `user` é texto ou lista de blocos no formato Anthropic (texto + imagem
    # base64); cada provedor traduz. `schema` nil = texto livre (`data` é
    # String); com schema, `data` é o Hash. `env` = variável da chave na IA
    # da suíte (Ai::Client); nil = o provedor só existe com chave da instalação.
    # Erro: Ai::Client::TransientError (429, 5xx, rede) ou Ai::Client::Error,
    # sempre com mensagem genérica (o corpo cru do provedor só no log).
    class Base
      Result = Data.define(:data, :usage)

      class << self
        attr_reader :key, :label, :default_model, :env, :base_url, :hint

        def describe(key:, label:, default_model:, capabilities:, models: [], env: nil, base_url: nil, custom_url: false, key_required: true, hint: nil)
          unknown = capabilities - Ai::CAPABILITIES.keys
          raise ArgumentError, "capacidade desconhecida: #{unknown.join(', ')}" if unknown.any?

          @key = key
          @label = label
          @default_model = default_model
          @capabilities = capabilities.freeze
          @models = models.freeze
          @env = env
          @base_url = base_url
          @custom_url = custom_url
          @key_required = key_required
          @hint = hint
        end

        def capabilities = @capabilities || []
        def models = @models || []
        def supports?(capability) = capabilities.include?(capability.to_sym)
        def custom_url? = @custom_url == true
        def key_required? = @key_required != false
      end

      def initialize(api_key: nil, base_url: nil)
        @api_key = api_key
        @base_url = (base_url.presence || self.class.base_url).to_s.chomp("/")
      end

      def complete(model:, system:, user:, schema:, max_tokens:, timeout:, effort: nil, temperature: nil) = raise(NotImplementedError)

      private

      def result(text, schema, input, output)
        raise Ai::Client::Error, "A IA não devolveu resposta. Tente de novo." if text.blank?

        Result.new(data: schema ? parse_json(text) : text.strip, usage: { input: input.to_i, output: output.to_i })
      end

      def parse_json(text)
        JSON.parse(text.to_s[/\{.*\}/m] || text.to_s, symbolize_names: true)
      rescue JSON::ParserError => e
        Rails.logger.warn("[ai] #{self.class.key} JSON inválido: #{e.message.truncate(120)}")
        raise Ai::Client::Error, "A IA respondeu num formato inesperado. Tente de novo."
      end

      # Resposta HTTP de erro: corpo só no log, mensagem genérica para fora.
      def http_error!(code, body)
        Rails.logger.warn("[ai] #{self.class.key} HTTP #{code}: #{body.to_s.first(500)}")
        klass = code.to_i == 429 || code.to_i >= 500 ? Ai::Client::TransientError : Ai::Client::Error
        raise klass, code.to_i.in?([ 401, 403 ]) ? "A chave do provedor foi recusada (#{code})." : "A IA não conseguiu responder agora (#{code}). Tente de novo."
      end

      # POST JSON num host fixo do provedor (a URL não vem do usuário).
      def post_json(url, body, headers, timeout)
        uri = URI(url)
        req = Net::HTTP::Post.new(uri)
        headers.merge("Content-Type" => "application/json").each { |k, v| req[k] = v }
        req.body = body.to_json
        res = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https", open_timeout: 10, read_timeout: timeout) { |h| h.request(req) }
        http_error!(res.code, res.body) unless res.is_a?(Net::HTTPSuccess)
        JSON.parse(res.body)
      rescue Net::OpenTimeout, Net::ReadTimeout
        raise Ai::Client::TransientError, "A IA demorou demais para responder (mais de #{timeout}s)."
      rescue SocketError, SystemCallError, OpenSSL::SSL::SSLError, JSON::ParserError => e
        Rails.logger.warn("[ai] #{self.class.key} rede: #{e.class}: #{e.message.truncate(200)}")
        raise Ai::Client::TransientError, "Falha de rede ao chamar a IA. Tente de novo."
      end

      def blocks(user) = user.is_a?(String) ? [ { type: "text", text: user } ] : Array(user).map { |b| b.to_h.with_indifferent_access }
      def text_of(user) = blocks(user).select { |b| b[:type].to_s == "text" }.pluck(:text).join("\n\n")
      def images_of(user) = blocks(user).select { |b| b[:type].to_s == "image" }.map { |b| b[:source] }
    end
  end
end
