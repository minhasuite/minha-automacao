# "Desde a última visita" (Ss::SinceLastVisitComponent no Início do web, SsSinceLastVisit no Início do app): o que
# aconteceu na casa desde `since`, nos locais que a pessoa vê. Alertas que abriram, automações que rodaram ou
# falharam e gravações das câmeras. Só itens com número; o rótulo vem no idioma da requisição.
#   => [{ key:, value: "3", label: "automações rodaram", tone: "accent"|"success"|"warn"|"danger" }]
module SinceLastVisit
  module_function

  MAX_DAYS = 30
  TONES = { "alerts" => "danger", "automations" => "success", "failed" => "warn", "recordings" => "accent" }.freeze

  def call(user:, since:, now: Time.current)
    since = [ since, now - MAX_DAYS.days ].max
    counts(Site.visible_to(user).select(:id), since..now).filter_map do |key, count|
      next unless count.positive?

      { key: key, value: count.to_s, label: I18n.t("since_last_visit.#{key}", count: count), tone: TONES.fetch(key) }
    end
  end

  def counts(sites, range)
    runs = AutomationRun.real.where(site_id: sites, created_at: range)
    { "alerts" => Alert.where(site_id: sites, opened_at: range).count,
      "automations" => runs.where(status: "done").count,
      "failed" => runs.where(status: "failed").count,
      "recordings" => CameraRecording.where(site_id: sites, created_at: range).count }
  end
end
