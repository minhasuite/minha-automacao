# Telas das automações da DSL (F6): resumo de cada bloco, rótulos dos
# valores e o selo de situação das execuções.
module AutomationsHelper
  RESULT_STYLES = { "ok" => %w[check-circle text-success], "false" => %w[x-circle text-muted], "error" => %w[exclamation-circle text-danger],
                    "simulated" => %w[eye text-accent], "waiting" => %w[clock text-accent], "timeout" => %w[clock text-warn],
                    "skipped" => %w[minus-circle text-warn], "tolerated" => %w[exclamation-circle text-warn],
                    "shadow" => %w[moon text-accent] }.freeze

  # Ícone e tom do bloco no editor (Ss::BlockComponent) pelo tipo da lista.
  KIND_ICONS = { triggers: "lightning-bolt", conditions: "filter", actions: "play", options: "switch-horizontal" }.freeze
  KIND_TONES = { triggers: :warn, conditions: :info, actions: :accent, options: :success }.freeze

  def dsl_type_choices(kind) = Automations::Dsl.catalog(kind).map { |type, s| [ s.label, type ] }

  # "Porta · para Aberto · por 5 min" (campos preenchidos, sem as listas).
  def block_summary(node, spec, points)
    spec.fields.filter_map do |fd|
      v = node[fd.name]
      next if v.nil? || Automations::Dsl.list_kind?(fd.kind)

      text = dsl_value_text(fd, v, node, points)
      fd.kind.in?(%i[point writable_point command template expr prompt]) ? text : "#{fd.label.sub(/ \(.*\)\z/, '').downcase} #{text}"
    end.join(" · ")
  end

  def dsl_value_text(fd, v, node, points)
    case fd.kind
    when :point, :writable_point then v.to_s.start_with?("$") ? t("automations.helper.field", name: v.delete_prefix("$")) : points[v]&.name || t("automations.helper.point_removed")
    when :value then (p = points[node["point"]]) ? point_value_label(p, v) : v.to_s
    when :duration then Automations::Dsl.duration_label(Automations::Dsl.seconds(v))
    when :days then Array(v).map { |d| Automations::Dsl.days[d.to_i] }.join("/")
    when :select then fd.choices.fetch(v, v)
    when :device_trigger then (p = points[node["point"]]) ? DeviceAutomations.triggers_for(p).fetch(v.to_s, v.to_s) : v.to_s
    when :device_condition then (p = points[node["point"]]) ? DeviceAutomations.conditions_for(p).fetch(v.to_s, v.to_s) : v.to_s
    when :bool then v ? t("automations.helper.yes") : t("automations.helper.no")
    when :channels then Array(v).map { |c| Notifier.channel_label(c) }.join(t("automations.helper.and")).downcase
    when :recipient then (s = points.values.first&.site) ? Notifier.recipient_label(v, s) : v.to_s
    when :camera then points[v]&.name || t("automations.helper.camera_removed")
    when :buttons then Array(v).pluck("title").join(", ")
    when :command then (p = points[node["point"]]) ? command_options(p).find { |_, c| c == v }&.first || command_label(v) : command_label(v)
    when :scene then Scene.find_by(id: v)&.name || t("automations.helper.scene_removed")
    when :script then Automation.find_by(id: v)&.name || t("automations.helper.script_removed")
    when :script_fields then v.map { |k, x| "#{k} = #{x}" }.join(", ")
    when :alert_rule then AlertRule.find_by(id: v)&.name || t("automations.helper.rule_removed")
    when :secret then t("automations.helper.stored")
    when :cameras, :points then Array(v).map { |id| points[id]&.name || t("automations.helper.point_removed") }.join(", ").truncate(80)
    when :areas, :tags then t("automations.helper.chosen", count: Array(v).size)
    when :dataset then Dataset.find_by(id: v)&.name || t("automations.helper.dataset_removed")
    when :kv then v.to_h.keys.join(", ")
    when :ai_output then v.is_a?(Hash) ? "JSON schema" : Array(v).filter_map { |f| f["name"] }.join(", ")
    else v.to_s.truncate(80)
    end
  end

  # Opções do campo "valor" conforme o ponto: liga/desliga e seleção viram lista.
  def dsl_value_choices(point)
    return unless point
    return [ true, false ].map { |b| [ point_value_label(point, b), b.to_s ] } if point.bool?

    return PointsHelper::STATE_TEXT[point.capability].map { |v, label| [ label, v ] } if point.capability == "timer"

    point.option_values.map { |o| [ point_value_label(point, o), o ] } if point.capability.in?(%w[enum gate])
  end

  def run_badge(run)
    tone = { "success" => "ss-badge-success", "danger" => "ss-badge-danger", "warn" => "ss-badge-warn", "info" => "ss-badge-accent" }.fetch(run.tone, "")
    tag.span(run.status_label, class: "ss-badge #{tone}")
  end

  def last_run_text(automation)
    return t("automations.helper.never_ran") unless automation.last_run_at

    "#{AutomationRun::STATUSES.fetch(automation.last_status, automation.last_status)} #{l(automation.last_run_at, format: :short)}"
  end

  def result_icon(result)
    name, color = RESULT_STYLES.fetch(result.to_s, %w[minus-circle text-muted])
    icon(name, "size-5 shrink-0 #{color}")
  end

  def block_dom_id(path) = "b-#{path.tr('.', '-')}"

  # Ações de um bloco do editor (Ss::BlockComponent) como ops do rascunho no servidor:
  # mover (dir=up|down), liga/desliga, duplicar e remover. Sem permissão, nada (só leitura).
  def block_ops(automation, path)
    return { duplicable: false, deletable: false } unless can?(:manage)

    url = ->(op) { draft_automation_path(automation, op: op, target: path) }
    { move_url: url.("move"), move_param: :dir, toggle_url: draft_automation_path(automation), toggle_method: :patch,
      toggle_params: { op: "toggle", target: path }, duplicate_url: url.("duplicate"), delete_url: url.("remove"), delete_method: :patch,
      delete_confirm_title: t("automations.block.remove") }
  end
end
