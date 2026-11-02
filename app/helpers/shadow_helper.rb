# Sombra (F10): rótulos da linha do tempo e resumo das comparações.
module ShadowHelper
  def shadow_action_label(action)
    Automations::ActionTypes[action]&.label || { "blocked" => t("shadow_labels.blocked"), "command" => t("shadow_labels.command") }.fetch(action, action.to_s)
  end

  def shadow_summary(report)
    list = ShadowReport::STATUSES.keys.excluding("idle").filter_map do |s|
      n = report.summary[s].to_i
      "#{n} #{ShadowReport.status_label(s).sub(/\A[A-Z](?=[a-z])/, &:downcase)}" if n.positive?
    end
    list.join(", ").presence || t("shadow_labels.none")
  end
end
