# Telas das automações da DSL (F6): resumo de cada bloco, rótulos dos
# valores e o selo de situação das execuções.
module AutomationsHelper
  KIND_TITLES = { triggers: "Quando", conditions: "Só se", actions: "Então" }.freeze
  KIND_HINTS = {
    triggers: "O que dispara: ponto mudou, limite, horário, sol, alerta, webhook ou só manual.",
    conditions: "Todas precisam valer na hora do disparo (opcional).",
    actions: "Executadas em ordem. Esperas sobrevivem a reinício do servidor."
  }.freeze
  RESULT_STYLES = { "ok" => %w[check-circle text-success], "false" => %w[x-circle text-muted], "error" => %w[exclamation-circle text-danger],
                    "simulated" => %w[eye text-accent], "waiting" => %w[clock text-accent], "timeout" => %w[clock text-warn],
                    "skipped" => %w[minus-circle text-warn] }.freeze

  def dsl_catalog(kind) = kind == :options ? { "option" => Automations::Dsl::OPTION } : Automations::Dsl::LIST_KINDS.merge(triggers: Automations::Dsl::TRIGGERS)[kind]

  def dsl_type_choices(kind) = dsl_catalog(kind).map { |type, s| [ s[:label], type ] }

  # "Porta · para Aberto · por 5 min" (campos preenchidos, sem as listas).
  def block_summary(node, spec, points)
    spec[:fields].filter_map do |fd|
      v = node[fd.name]
      next if v.nil? || Automations::Dsl::LIST_KINDS.key?(fd.kind)

      text = dsl_value_text(fd, v, node, points)
      fd.kind.in?(%i[point writable_point command template expr]) ? text : "#{fd.label.sub(/ \(.*\)\z/, '').downcase} #{text}"
    end.join(" · ")
  end

  def dsl_value_text(fd, v, node, points)
    case fd.kind
    when :point, :writable_point then points[v]&.name || "ponto removido"
    when :value then (p = points[node["point"]]) ? point_value_label(p, v) : v.to_s
    when :duration then Automations::Dsl.duration_label(Automations::Dsl.seconds(v))
    when :days then Array(v).map { |d| Automations::Dsl::DAYS[d.to_i] }.join("/")
    when :select then fd.options.fetch(v, v)
    when :bool then v ? "sim" : "não"
    when :channels then Array(v).map { |c| Notifier::CHANNELS.fetch(c, c) }.join(" e ").downcase
    when :command then command_label(v)
    when :scene then Scene.find_by(id: v)&.name || "cena removida"
    when :alert_rule then AlertRule.find_by(id: v)&.name || "regra removida"
    else v.to_s.truncate(80)
    end
  end

  # Opções do campo "valor" conforme o ponto: liga/desliga e seleção viram lista.
  def dsl_value_choices(point)
    return unless point
    return [ true, false ].map { |b| [ point_value_label(point, b), b.to_s ] } if point.bool?

    point.option_values.map { |o| [ point_value_label(point, o), o ] } if point.capability.in?(%w[enum gate])
  end

  def run_badge(run)
    tone = { "success" => "ss-badge-success", "danger" => "ss-badge-danger", "warn" => "ss-badge-warn", "info" => "ss-badge-accent" }.fetch(run.tone, "")
    tag.span(run.status_label, class: "ss-badge #{tone}")
  end

  def last_run_text(automation)
    return "Nunca rodou" unless automation.last_run_at

    "#{AutomationRun::STATUSES.fetch(automation.last_status, automation.last_status)} #{l(automation.last_run_at, format: :short)}"
  end

  def result_icon(result)
    name, color = RESULT_STYLES.fetch(result.to_s, %w[minus-circle text-muted])
    icon(name, "size-5 shrink-0 #{color}")
  end

  def block_dom_id(path) = "b-#{path.tr('.', '-')}"
end
