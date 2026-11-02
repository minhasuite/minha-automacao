module Ai
  module Providers
    # Ollama local (`/api/chat`, sem streaming). A URL é digitada pelo usuário,
    # então passa pelo SafeHttp: endereço da rede de casa precisa estar
    # liberado em Configurações → Sistema (Saída HTTP). Chave opcional (Bearer,
    # para quem põe o Ollama atrás de um proxy). Imagem só em modelo de visão
    # (llava, qwen2.5vl, gemma3); `format` aceita JSON schema.
    class Ollama < Base
      describe key: "ollama", label: "Ollama (local)", default_model: "llama3.2", models: %w[llama3.2 gemma3 qwen2.5vl llava],
               base_url: "http://localhost:11434", custom_url: true, key_required: false,
               capabilities: %i[text image structured tools temperature],
               hint: "Libere o endereço do Ollama em Configurações → Sistema → Saída HTTP (ex.: 192.168.68.50)."
      texts en: { label: "Ollama (local)", hint: "Allow the Ollama address in Settings → System → HTTP egress (e.g. 192.168.68.50)." },
            es: { label: "Ollama (local)", hint: "Habilita la dirección de Ollama en Configuración → Sistema → Salida HTTP (ej.: 192.168.68.50)." }

      def complete(model:, system:, user:, schema:, max_tokens:, timeout:, effort: nil, temperature: nil) # rubocop:disable Lint/UnusedMethodArgument
        message = { role: "user", content: text_of(user) }
        images = images_of(user).pluck(:data)
        message[:images] = images if images.any?
        options = { num_predict: max_tokens }
        options[:temperature] = temperature unless temperature.nil?
        body = { model: model, stream: false, messages: [ { role: "system", content: system }, message ], options: options }
        body[:format] = schema if schema
        headers = { "Content-Type" => "application/json" }
        headers["Authorization"] = "Bearer #{@api_key}" if @api_key.present?
        res = SafeHttp.request("POST", "#{@base_url}/api/chat", headers: headers, body: body.to_json, timeout: timeout)
        http_error!(res.status, res.body) if res.status >= 400
        json = JSON.parse(res.body)
        result(json.dig("message", "content"), schema, json["prompt_eval_count"], json["eval_count"])
      rescue SafeHttp::Error => e
        raise Ai::Client::TransientError, "Ollama: #{e.message}"
      rescue JSON::ParserError
        raise Ai::Client::Error, "O Ollama respondeu num formato inesperado."
      end
    end
  end
end
