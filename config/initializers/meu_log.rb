# Telemetria no meulog (meulog.minhasuite.com), o monitor de erro da suíte.
# Sem MEULOG_URL + MEULOG_TOKEN o SDK é no-op: dev e test ficam sem telemetria.
#
#   MEULOG_URL   https://meulog.minhasuite.com/minhasuite  (a CONTA vai no caminho)
#   MEULOG_TOKEN token de SERVIDOR do projeto "Minha Automação (API)"
Rails.application.config.after_initialize do
  MeuLog.configure do |c|
    c.url = ENV.fetch("MEULOG_URL", nil)
    c.token = ENV.fetch("MEULOG_TOKEN", nil)
    c.ambiente = Rails.env.production? ? "prod" : Rails.env.to_s
    c.versao = ENV["APP_VERSION"].presence || ENV["GIT_SHA"].presence
    c.logger = Rails.logger
  end

  if MeuLog.configured?
    Rails.error.subscribe(MeuLogErrorSubscriber.new)
    Rails.logger.info("[meulog] ativo")
  end
end
