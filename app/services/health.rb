# Saúde do sistema (Configurações → Saúde, só administradores). Cada
# verificação é um plugin: classe `< Health::Check` com `describe key:,
# label:, icon:` [, `alerts: false`] e `items(tenant)` → lista de
# `Health::Item` + nome em `CHECKS`. A tela, o aviso (`HealthCheckJob`) e a
# checagem da troca (`rake cutover:check`) só perguntam ao registro.
module Health
  CHECKS = %w[Integrations Devices Queues Backup Disk Runtime Shadow Cutover].freeze
  STATUSES = %w[ok warn error].freeze
  LABELS = { "ok" => "Ok", "warn" => "Atenção", "error" => "Com erro" }.freeze
  TONES = { "ok" => "success", "warn" => "warn", "error" => "danger" }.freeze
  BOOTED_AT = Time.current

  Item = Data.define(:key, :status, :title, :detail, :at) do
    def initialize(key:, status:, title:, detail: nil, at: nil)
      raise ArgumentError, "status inválido: #{status}" unless STATUSES.include?(status.to_s)

      super(key: key.to_s, status: status.to_s, title: title, detail: detail, at: at)
    end
  end

  Result = Data.define(:check, :items) do
    def status = Health.worst(items.map(&:status))
    def problems = items.reject { |i| i.status == "ok" }
  end

  # Interface comum de uma verificação.
  class Check
    class << self
      attr_reader :key, :label, :icon

      def describe(key:, label:, icon:, alerts: true)
        @key = key
        @label = label
        @icon = icon
        @alerts = alerts
      end

      # false = só informa na tela (ex.: o que falta para a troca), sem aviso.
      def alerts? = @alerts != false

      def items(_tenant) = raise(NotImplementedError)

      def item(**) = Item.new(**)
    end
  end

  module_function

  def checks = CHECKS.map { |name| Checks.const_get(name) }
  def check(key) = checks.find { |c| c.key == key.to_s }

  def worst(statuses) = statuses.max_by { |s| STATUSES.index(s) } || "ok"

  # Uma verificação que quebra vira item de erro dela, sem derrubar as outras.
  def run(tenant, only: nil)
    (only ? Array(only).map { |k| check(k) }.compact : checks).map do |c|
      Result.new(check: c, items: ActsAsTenant.with_tenant(tenant) { c.items(tenant) })
    rescue StandardError => e
      Result.new(check: c, items: [ Item.new(key: "falha", status: "error", title: "A verificação falhou", detail: e.message.truncate(200)) ])
    end
  end

  # Aviso aos administradores (canal do app) para cada item com erro: um por problema por dia.
  def alert!(tenant, now: Time.current)
    run(tenant).select { |r| r.check.alerts? }.flat_map do |r|
      r.items.select { |i| i.status == "error" }.filter_map do |i|
        ActsAsTenant.with_tenant(tenant) do
          Notifier.notify!(kind: "sistema", title: "#{r.check.label}: #{i.title}", body: i.detail,
                           data: { "url" => "/configuracoes/saude", "tag" => "saude:#{r.check.key}:#{i.key}" },
                           dedup_key: "saude:#{tenant.id}:#{r.check.key}:#{i.key}:#{now.to_date}")
        end
      end
    end
  end
end
