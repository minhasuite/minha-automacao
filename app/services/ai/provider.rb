# IA da SUÍTE (planos, tiers): a chave é sempre env (`env` do plugin) e o
# admin escolhe provedor e modelo por tier (AiTierConfig). Os provedores são
# os mesmos plugins de Ai::PROVIDERS; só entram aqui os que declaram `env`.
# A IA da instalação (chave do usuário) é o Ai::Request.
module Ai
  module Provider
    DEFAULT = "gemini".freeze

    module_function

    def names = Ai.providers.select(&:env).map(&:key)

    def configured?(name)
      plugin = Ai.provider(name)
      plugin&.env.present? && ENV[plugin.env].present?
    end

    def for(name)
      plugin = Ai.provider(name)
      raise Ai::Client::Error, "provedor desconhecido: #{name.inspect}" unless plugin&.env

      plugin.new(api_key: ENV.fetch(plugin.env))
    end
  end
end
