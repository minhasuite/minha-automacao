# Catálogo de provedores de IA. A credencial é SEMPRE env; o admin escolhe
# provedor e modelo por tier (AiTierConfig).
module Ai
  module Provider
    DEFAULT = "gemini".freeze

    CATALOG = {
      "anthropic" => { label: "Anthropic", env: "ANTHROPIC_API_KEY" },
      "gemini" => { label: "Google Gemini", env: "GEMINI_API_KEY" },
      "openai" => { label: "OpenAI", env: "OPENAI_API_KEY", base_url: "https://api.openai.com/v1" }
    }.freeze

    module_function

    def names = CATALOG.keys

    def config(name) = CATALOG.fetch(name.to_s) { raise Ai::Client::Error, "provedor desconhecido: #{name.inspect}" }

    def configured?(name)
      ENV[config(name)[:env]].present?
    rescue Ai::Client::Error
      false
    end

    # `case` e não constantize: reflexão a partir de string é o que o Brakeman
    # (com razão) não deixa passar.
    def for(name)
      cfg = config(name)
      case name.to_s
      when "anthropic" then Providers::Anthropic.new(cfg)
      when "gemini" then Providers::Gemini.new(cfg)
      else Providers::OpenaiCompatible.new(name.to_s, cfg)
      end
    end
  end
end
