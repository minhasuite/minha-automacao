# Saúde do sistema (Configurações → Saúde, só administradores). Cada
# verificação é um plugin: classe `< Health::Check` com `describe key:,
# label:, icon:` [, `alerts: false`] e `items(tenant)` → lista de
# `Health::Item` + nome em `CHECKS`. A tela, o aviso (`HealthCheckJob`) e a
# checagem da troca (`rake cutover:check`) só perguntam ao registro.
#
# Reparos (ondaA2 A12, o "Reparos" do HA): o item pode trazer `fix:` com o
# caminho guiado (`{ label:, url: }`) e a verificação pode corrigir com um
# clique (`repair(tenant, item_key)` → mensagem). Problema ignorado fica em
# `tenants.settings["health_ignored"]`: não conta no status nem avisa.
module Health
  CHECKS = %w[Integrations Devices Queues Backup Disk Runtime Shadow Cutover].freeze
  STATUSES = %w[ok warn error].freeze
  LABELS = { "ok" => "Ok", "warn" => "Atenção", "error" => "Com erro" }.freeze
  TONES = { "ok" => "success", "warn" => "warn", "error" => "danger" }.freeze
  BOOTED_AT = Time.current

  Item = Data.define(:key, :status, :title, :detail, :at, :fix, :ignored) do
    def initialize(key:, status:, title:, detail: nil, at: nil, fix: nil, ignored: false)
      raise ArgumentError, "status inválido: #{status}" unless STATUSES.include?(status.to_s)

      super(key: key.to_s, status: status.to_s, title: title, detail: detail, at: at, fix: fix, ignored: ignored)
    end

    def problem? = status != "ok"
  end

  Result = Data.define(:check, :items) do
    def status = Health.worst(items.reject(&:ignored).map(&:status))
    def problems = items.select { |i| i.problem? && !i.ignored }
  end

  # Interface comum de uma verificação.
  class Check
    extend PluginTexts
    translates :label
    texts "pt-BR" => { last_ok: "último ok %{at}", failed: "falhou: %{error}", not_run: "Ainda não rodou", none: "Nenhum" },
          en: { last_ok: "last ok %{at}", failed: "failed: %{error}", not_run: "Hasn't run yet", none: "None" },
          es: { last_ok: "último ok %{at}", failed: "falló: %{error}", not_run: "Todavía no se ejecutó", none: "Ninguno" }

    class << self
      attr_reader :key, :icon

      def describe(key:, label:, icon:, alerts: true)
        @key = key
        @label = label
        @icon = icon
        @alerts = alerts
      end

      # false = só informa na tela (ex.: o que falta para a troca), sem aviso.
      def alerts? = @alerts != false

      def items(_tenant) = raise(NotImplementedError)

      # Correção de um clique do item (→ mensagem) ou nil = não corrige sozinha.
      def repair(_tenant, _key) = nil
      def repairs? = method(:repair).owner != Check.singleton_class

      def item(**) = Item.new(**)
    end
  end

  module_function

  def checks = CHECKS.map { |name| Checks.const_get(name) }
  def check(key) = checks.find { |c| c.key == key.to_s }

  def label(status) = I18n.t("health.labels.#{status}", default: LABELS[status].to_s)
  def worst(statuses) = statuses.max_by { |s| STATUSES.index(s) } || "ok"

  # Uma verificação que quebra vira item de erro dela, sem derrubar as outras.
  def run(tenant, only: nil)
    skip = ignored(tenant)
    (only ? Array(only).map { |k| check(k) }.compact : checks).map do |c|
      items = ActsAsTenant.with_tenant(tenant) { c.items(tenant) }
      Result.new(check: c, items: items.map { |i| i.problem? && skip.include?("#{c.key}:#{i.key}") ? i.with(ignored: true) : i })
    rescue StandardError => e
      Result.new(check: c, items: [ Item.new(key: "falha", status: "error", title: I18n.t("health.check_failed"), detail: e.message.truncate(200)) ])
    end
  end

  # Aviso aos administradores (canal do app) para cada item com erro: um por problema por dia.
  def alert!(tenant, now: Time.current)
    run(tenant).select { |r| r.check.alerts? }.flat_map do |r|
      r.items.select { |i| i.status == "error" && !i.ignored }.filter_map do |i|
        ActsAsTenant.with_tenant(tenant) do
          Notifier.notify!(kind: "sistema", title: "#{r.check.label}: #{i.title}", body: i.detail,
                           data: { "url" => "/configuracoes/saude", "tag" => "saude:#{r.check.key}:#{i.key}" },
                           dedup_key: "saude:#{tenant.id}:#{r.check.key}:#{i.key}:#{now.to_date}")
        end
      end
    end
  end

  def ignored(tenant) = Array(tenant.settings["health_ignored"])

  def ignore!(tenant, ref, on: true)
    list = on ? (ignored(tenant) | [ ref.to_s ]) : ignored(tenant) - [ ref.to_s ]
    tenant.update!(settings: tenant.settings.merge("health_ignored" => list))
  end

  # Correção de um clique: a verificação diz o que fez (ou nil se não sabe corrigir).
  def repair!(tenant, check_key, item_key)
    c = check(check_key) or return nil
    ActsAsTenant.with_tenant(tenant) { c.repair(tenant, item_key.to_s) }
  end
end
