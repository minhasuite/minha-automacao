# Sombra (F10): rótulos da linha do tempo e resumo das comparações.
module ShadowHelper
  def shadow_action_label(action)
    Automations::ActionTypes[action]&.label || { "blocked" => "Segurado na rede", "command" => "Comando" }.fetch(action, action.to_s)
  end

  def shadow_summary(report)
    list = ShadowReport::STATUSES.keys.excluding("idle").filter_map do |s|
      n = report.summary[s].to_i
      "#{n} #{ShadowReport.status_label(s).downcase}" if n.positive?
    end
    list.join(", ").presence || "sem disparos"
  end
end
