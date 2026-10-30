# Telas das primitivas de automação (F4).
module AutomationHelper
  COMMAND_CHOICES = { "Ligar" => "on", "Desligar" => "off", "Alternar" => "toggle", "Pulsar (portão)" => "pulse",
                      "Apertar (botão)" => "press", "Ajustar valor" => "set", "Selecionar opção" => "select",
                      "Iniciar limpeza (robô)" => "start", "Pausar (robô)" => "pause", "Parar (robô)" => "stop",
                      "Voltar à base (robô)" => "home", "Lavar o pano (robô)" => "wash_mop", "Secar o pano (robô)" => "dry_mop",
                      "Esvaziar (robô)" => "empty", "Anunciar (Echo)" => "announce", "Falar (Echo)" => "speak",
                      "Executar (script)" => "run" }.freeze

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
    parts << "nos dois sentidos" if link.bidirectional
    parts << "quando ficar #{point_value_label(link.source_point, link.trigger_value.nil? || link.trigger_value)}" if link.mode == "trigger"
    parts.join(" · ")
  end

  def schedule_detail(schedule)
    action = schedule.scene ? "cena #{schedule.scene.name}" : [ command_label(schedule.command), schedule.value, schedule.point.name ].compact.join(" ")
    "#{schedule.when_label} · #{action}"
  end

  def notify_detail(rule)
    on = rule.to_value.nil? ? "a cada mudança" : "quando ficar #{point_value_label(rule.point, rule.to_value)}"
    "#{on} · #{channels_label(rule.channels)}"
  end

  def alert_rule_detail(rule)
    value = rule.value.is_a?(Numeric) ? rule.value : point_value_label(rule.point, rule.value)
    cond = "#{rule.point.name} #{rule.operator_label} #{value}"
    cond += " por #{rule.for_min} min" if rule.for_s.positive?
    repeat = rule.repeat_s ? ", repete a cada #{rule.repeat_min} min" : ""
    "#{cond} · #{rule.severity_label} · #{count_label(rule.escalation.size, 'etapa', 'etapas')}#{repeat}"
  end

  def channels_label(channels) = channels.map { |c| Notifier.channel_label(c) }.join(" e ").downcase
end
