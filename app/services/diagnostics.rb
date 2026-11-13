# Saúde dos aparelhos (docs/saude-aparelhos.md): diagnóstico do que está
# cadastrado no local, com o motivo provável e reparos seguros.
#
# Aberto/fechado: regra nova = classe `< Diagnostics::Rule` em
# `app/services/diagnostics/rules.rb` (ou arquivo próprio em
# `diagnostics/rules/`) com `describe key:, label:, description:, subject:,
# severity:` + `applies?(sujeito, ctx)` [+ `finding`, `fixes`] e o nome em
# `RULES`; reparo novo = classe `< Diagnostics::Fix` + nome em `FIXES`.
# Limiares são dado (`config/device_diagnostics.yml`, o local muda por cima em
# `sites.settings["device_health"]`); textos vêm da própria classe (pt/en/es).
#
# Nada aqui comanda aparelho: os reparos só leem de novo (reconectar),
# varrem a conta, mudam cadastro (IP, área), apagam cadastro órfão (com
# AuditEvent) ou levam a outra tela (substituir, editar, parear).
module Diagnostics
  class Error < StandardError; end

  RULES = %w[IntegrationDown HubDown Offline IpChanged RemovedFromAccount NoPoints Duplicate CameraNoStream
             NoArea BatteryLow ZeroReading ValueStuck ValueJump].freeze
  FIXES = %w[ApplyIp Reconnect Scan Reconfigure Pair Replace SetArea Edit DeleteDevice].freeze
  SEVERITIES = %w[info warn error].freeze
  TONES = { "info" => "info", "warn" => "warn", "error" => "danger" }.freeze
  # Severidade → status da Saúde (informação não é problema lá).
  HEALTH = { "info" => "ok", "warn" => "warn", "error" => "error" }.freeze
  SETTINGS_KEY = "device_health".freeze
  AUDIT_SNOOZE = "device_health.snooze".freeze

  # Um achado: regra + sujeito (aparelho, ponto ou integração) + aparelho a
  # que o reparo se aplica (nil quando o sujeito é a integração).
  Finding = Data.define(:rule, :subject, :device, :severity, :reason, :detail, :fixes, :since, :snoozed_until) do
    def ref = "#{rule.key}:#{subject.id}"
    def point = subject.is_a?(Point) ? subject : nil
    def integration = subject.is_a?(Integration) ? subject : device&.integration
    def snoozed? = snoozed_until.present?
    def area = point&.area || device&.area
    def site_id = subject.site_id
    def name = subject.name
    def health_status = HEALTH.fetch(severity)
  end

  module_function

  def config = @config ||= YAML.load_file(Rails.root.join("config/device_diagnostics.yml")).freeze
  def reset_config! = @config = nil

  def rules = RULES.map { |n| Rules.const_get(n) }
  def rule(key) = rules.find { |r| r.key == key.to_s }
  def fixes = FIXES.map { |n| Fixes.const_get(n) }
  def fix(key) = fixes.find { |f| f.key == key.to_s }

  # Ajustes do local: padrão do YAML + o que o local mudou.
  def settings(site) = config.fetch("settings").merge(site.settings.to_h.dig(SETTINGS_KEY, "values").to_h)

  # Grava os ajustes do formulário (só as chaves de `editable`, cada uma no tipo e faixa).
  def update_settings!(site, form)
    values = config.fetch("editable").each_with_object({}) do |(k, spec), h|
      next unless form.key?(k)

      h[k] = cast(form[k], spec)
    end
    store!(site) { |s| s["values"] = s["values"].to_h.merge(values.compact) }
  end

  def cast(raw, spec)
    return ActiveModel::Type::Boolean.new.cast(raw) ? true : false if spec["type"] == "boolean"

    n = Integer(raw.to_s.strip, exception: false) or return nil
    n.clamp(spec.fetch("min", n), spec.fetch("max", n))
  end

  # Silenciar um achado por N dias (não conta na Saúde nem avisa).
  def snooze!(site, ref, days, user: nil)
    days = days.to_i
    raise Error, "prazo inválido" unless config.fetch("snooze_days").include?(days)

    until_at = days.days.from_now
    store!(site) { |s| s["snoozed"] = live_snoozes(s).merge(ref.to_s => until_at.iso8601) }
    AuditEvent.create!(tenant_id: site.tenant_id, user_id: user&.id, action: AUDIT_SNOOZE, auditable_type: "Site", auditable_id: site.id,
                       details: { "ref" => ref.to_s, "until" => until_at.iso8601 })
    until_at
  end

  def unsnooze!(site, ref) = store!(site) { |s| s["snoozed"] = live_snoozes(s).except(ref.to_s) }

  def snoozes(site, now: Time.current) = live_snoozes(site.settings.to_h[SETTINGS_KEY].to_h, now: now)

  def live_snoozes(store, now: Time.current)
    store["snoozed"].to_h.select { |_ref, at| (t = Time.zone.parse(at.to_s)) && t > now }
  end

  def store!(site)
    site.reload
    s = site.settings.to_h[SETTINGS_KEY].to_h.dup
    yield s
    site.update!(settings: site.settings.to_h.merge(SETTINGS_KEY => s))
  end

  # Todos os achados do local (silenciados marcados). Regra que quebra fica
  # no log e não derruba as outras.
  def run(site, now: Time.current)
    ctx = Context.new(site, now: now)
    snoozed = snoozes(site, now: now)
    rules.flat_map do |rule|
      ctx.subjects(rule.subject).filter_map do |s|
        next unless rule.applies?(s, ctx)

        f = rule.finding(s, ctx) or next
        (at = snoozed[f.ref]) ? f.with(snoozed_until: Time.zone.parse(at)) : f
      end
    rescue StandardError => e
      Rails.logger.warn("[diagnostics] #{rule.key}: #{e.class}: #{e.message}")
      []
    end
  end

  # Contagem por severidade dos achados que contam (sem silenciados e sem informação).
  def problems(findings) = findings.reject { |f| f.snoozed? || f.severity == "info" }

  def worst(findings) = findings.map(&:severity).max_by { |s| SEVERITIES.index(s) }

  # Aviso de bateria baixa (e das outras regras com `notify: true`): um por
  # achado por semana, para dono e administradores. Ligado por local
  # (`battery_notify`). Chamado pelo HealthCheckJob.
  def notify!(tenant, now: Time.current)
    ActsAsTenant.with_tenant(tenant) do
      Site.find_each.flat_map do |site|
        next [] unless settings(site)["battery_notify"]

        run(site, now: now).select { |f| f.rule.notify? && !f.snoozed? }.filter_map do |f|
          Notifier.notify!(kind: "sistema", title: "#{f.rule.label}: #{f.name}", body: [ f.reason, f.detail ].compact.join(" · "),
                           data: { "url" => Rails.application.routes.url_helpers.device_health_path(site_id: site.id), "tag" => "saude-aparelhos:#{f.ref}" },
                           dedup_key: "saude-aparelhos:#{f.ref}:#{now.to_date.cweek}-#{now.to_date.cwyear}")
        end
      end
    end
  end
end
