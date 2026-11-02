# Telas das primitivas de automação (F4).
module AutomationHelper
  # rótulo (no idioma da tela) → comando.
  COMMAND_CHOICES = %w[on off toggle pulse press set select start pause stop home wash_mop dry_mop empty announce speak routine run]
                    .to_h { |c| [ LocalizedLabel.new("labels.command_choices.#{c}"), c ] }.freeze

  def point_choices(site, writable: false)
    scope = site.points.includes(:device).ordered
    scope = scope.where(writable: true) if writable
    scope.map { |p| [ "#{p.name} · #{p.device.name}", p.id ] }
  end

  # As listas da página de automação do local, ou só as de um ponto.
  def automation_lists(site, point = nil)
    of_point = ->(rel) { point ? rel.where(point_id: point.id) : rel }
    links = site.point_links
    links = links.where(source_point_id: point.id).or(site.point_links.where(target_point_id: point.id)) if point
    { schedules: of_point.call(site.schedules).includes(:point, :scene).order(:name).to_a,
      links: links.includes(:source_point, :target_point).order(:created_at).to_a,
      notify_rules: of_point.call(site.notify_rules).includes(:point).order(:created_at).to_a,
      alert_rules: of_point.call(site.alert_rules).includes(:point).order(:name).to_a }
  end

  def command_label(command) = COMMAND_CHOICES.key(command) || command

  # [rótulo, comando] que o ponto aceita; helper usa os rótulos do plugin.
  def command_options(point)
    return COMMAND_CHOICES.to_a unless point

    labels = COMMAND_CHOICES.invert.merge(point.helper_type&.command_labels || {})
    Points::Command.commands_for(point).map { |c| [ labels.fetch(c, c), c ] }
  end

  def link_detail(link)
    parts = [ link.mode_label ]
    parts << t("rules.both_ways") if link.bidirectional
    parts << t("rules.when_becomes", value: point_value_label(link.source_point, link.trigger_value.nil? || link.trigger_value)) if link.mode == "trigger"
    parts.join(" · ")
  end

  def schedule_detail(schedule)
    action = schedule.scene ? t("rules.scene", name: schedule.scene.name) : [ command_label(schedule.command), schedule.value, schedule.point.name ].compact.join(" ")
    "#{schedule.when_label} · #{action}"
  end

  def notify_detail(rule)
    on = rule.to_value.nil? ? t("rules.every_change") : t("rules.when_becomes", value: point_value_label(rule.point, rule.to_value))
    "#{on} · #{channels_label(rule.channels)}"
  end

  def alert_rule_detail(rule)
    value = rule.value.is_a?(Numeric) ? rule.value : point_value_label(rule.point, rule.value)
    cond = "#{rule.point.name} #{rule.operator_label} #{value}"
    cond += " #{t('rules.for_min', n: rule.for_min)}" if rule.for_s.positive?
    repeat = rule.repeat_s ? t("rules.repeat", n: rule.repeat_min) : ""
    "#{cond} · #{rule.severity_label} · #{t('rules.steps', count: rule.escalation.size)}#{repeat}"
  end

  def channels_label(channels) = channels.map { |c| Notifier.channel_label(c) }.join(t("rules.and")).downcase
end
