# Assinante do Rails.error que manda a exceção ao meulog. Vê request, job do
# Solid Queue e rails runner — tudo que passa pelo Rails.error.
class MeuLogErrorSubscriber
  # Ruído conhecido: 404 de rota e de registro não é bug.
  IGNORED = %w[
    ActiveRecord::RecordNotFound ActionController::RoutingError
    ActionController::UnknownFormat ActionDispatch::Http::MimeNegotiation::InvalidType
  ].freeze

  def report(error, handled:, severity: nil, context: {}, source: nil)
    return if handled
    return if IGNORED.include?(error.class.name)
    return unless MeuLog.configured?

    ctx = (context || {}).dup
    ctx[:severity] = severity if severity
    ctx[:source] = source if source
    MeuLog.notify_como(error, usuario: ctx.delete(:usuario), cliente: ctx.delete(:empresa), **ctx.symbolize_keys)
  rescue StandardError => e
    # Monitor que derruba o que ele monitora não é monitor.
    Rails.logger.error("[MeuLogErrorSubscriber] #{e.class}: #{e.message}")
  end
end
