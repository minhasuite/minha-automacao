module Points
  # "Redefinir estado": o técnico corrige à mão o valor de um sensor que perdeu
  # o evento antes de chegar ao servidor (sensor de porta só fala quando muda,
  # então nem a nuvem sabe; 10/11/2026: portão "aberto" por horas). Só ponto que
  # não recebe comando; passa pelo `report!` (automações e alertas veem a
  # mudança) e vira AuditEvent `reset` na linha do tempo do ponto.
  #
  # Até o aparelho falar de novo por conta própria (evento empurrado), a
  # releitura do estado completo (nuvem, conexão curta) não desfaz a correção:
  # `address.reset_at` marca isso e o driver limpa no próximo evento.
  module Reset
    class Error < StandardError; end

    def self.allowed?(point) = !point.writable && point.capability.in?(CAPABILITIES) && point.helper.blank?

    # Sensores de estado: o que pode ficar preso num valor que já passou.
    CAPABILITIES = %w[contact motion tamper problem enum measure].freeze

    def self.call(point, raw, user:)
      raise Error, I18n.t("points.reset.not_allowed") unless allowed?(point)

      value = point.cast(raw.to_s)
      raise Error, I18n.t("points.reset.invalid") if value.nil? || (point.capability == "enum" && point.option_values.any? && !value.to_s.in?(point.option_values))

      from = point.value
      Point.transaction do
        point.update_columns(address: point.address.merge("reset_at" => Time.current.iso8601)) # rubocop:disable Rails/SkipsModelValidations
        AuditEvent.create!(tenant_id: point.tenant_id, user_id: user&.id, action: "reset", auditable_type: "Point", auditable_id: point.id,
                           details: { "from" => from, "to" => value, "quality" => point.quality })
      end
      point.report!(value)
      point
    end

    # Evento que o aparelho empurrou: a correção manual deixa de valer.
    def self.release!(point)
      return unless point.address.key?("reset_at")

      point.update_columns(address: point.address.except("reset_at")) # rubocop:disable Rails/SkipsModelValidations
    end

    def self.held?(point) = point.address.key?("reset_at")
  end
end
