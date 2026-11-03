module Integrations
  # Log de depuração por integração (resto, 7.7; o "Ativar log de depuração"
  # do HA): ligado na tela, junta por até 24 h o que passa pela integração
  # (varredura, leitura de cada aparelho, comandos e erros, além do que o
  # plugin mandar por `Plugin.debug`). Desligar devolve o texto para baixar.
  # Saneado (Sensitive.scrub) antes de guardar: nada de IP, token ou senha.
  # ponytail: lista no Rails.cache (solid_cache no servidor, comum a web e
  # worker); duas gravações ao mesmo tempo podem perder uma linha. Tabela
  # própria se isso pesar.
  module DebugLog
    MAX_LINES = 2000
    TTL = 24.hours
    # "token=…", "password: …", "Bearer …" no texto livre que o plugin manda.
    SECRET = /\b(token|access_token|refresh_token|password|senha|secret|api_key|apikey|authorization|bearer|local_key)\b["']?\s*[=:]?\s*["']?[^\s,;"'&]+/i

    module_function

    def key(integration) = "integration_debug/#{integration.id}"
    def expires_at(integration) = (t = integration.settings["debug_until"]).present? ? Time.zone.parse(t.to_s) : nil
    def on?(integration) = integration.present? && expires_at(integration)&.future? == true

    def start!(integration)
      integration.update!(settings: integration.settings.merge("debug_until" => TTL.from_now.iso8601))
      Rails.cache.write(key(integration), [], expires_in: TTL + 1.hour)
      log(integration, "debug ligado (#{integration.driver})")
    end

    # Desliga e devolve o texto juntado.
    def stop!(integration)
      text = lines(integration).join("\n")
      integration.update!(settings: integration.settings.except("debug_until"))
      Rails.cache.delete(key(integration))
      text
    end

    def lines(integration) = Array(Rails.cache.read(key(integration)))

    def log(integration, message)
      return unless on?(integration)

      text = Sensitive.scrub(message.to_s.squish).gsub(SECRET, "\\1=#{Sensitive::MASK}")
      line = "#{Time.current.iso8601(3)} #{text.truncate(1000)}"
      Rails.cache.write(key(integration), (lines(integration) << line).last(MAX_LINES), expires_in: TTL + 1.hour)
    rescue StandardError
      nil # log nunca derruba quem loga
    end
  end
end
