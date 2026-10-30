module Ai
  module Providers
    # OpenAI `/chat/completions` (Net::HTTP direto: um POST JSON não justifica
    # SDK). Imagem do formato Anthropic vira `image_url` com data URI. Sem
    # temperatura: os modelos de raciocínio (gpt-5) recusam valor fora do padrão.
    class Openai < Base
      describe key: "openai", label: "OpenAI", env: "OPENAI_API_KEY", default_model: "gpt-5-mini", models: %w[gpt-5-mini gpt-5],
               base_url: "https://api.openai.com/v1", capabilities: %i[text image structured tools],
               hint: "Chave em platform.openai.com → API keys."

      def complete(model:, system:, user:, schema:, max_tokens:, timeout:, effort: nil, temperature: nil) # rubocop:disable Lint/UnusedMethodArgument
        body = { model: model, messages: [ { role: "system", content: system }, { role: "user", content: translate(user) } ],
                 max_completion_tokens: max_tokens }
        body[:response_format] = { type: "json_schema", json_schema: { name: "resposta", strict: true, schema: schema } } if schema
        body[:reasoning_effort] = effort if effort.present?
        json = post_json("#{@base_url}/chat/completions", body, { "Authorization" => "Bearer #{@api_key}" }, timeout)
        usage = json["usage"] || {}
        result(json.dig("choices", 0, "message", "content"), schema, usage["prompt_tokens"], usage["completion_tokens"])
      end

      private

      def translate(user)
        return user if user.is_a?(String)

        blocks(user).map do |b|
          if b[:type].to_s == "image" then { type: "image_url", image_url: { url: "data:#{b.dig(:source, :media_type)};base64,#{b.dig(:source, :data)}" } }
          else { type: "text", text: b[:text].to_s }
          end
        end
      end
    end
  end
end
