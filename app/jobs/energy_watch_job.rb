# Consumo fora do normal (tela Energia): a cada hora, depois dos rollups,
# confere a hora que fechou em cada local com o aviso ligado
# (`EnergyUse.watch`) e manda UM aviso por local com todos os aparelhos fora
# do normal (agrupado pela tag; um por hora pelo dedup_key). Ver docs/energia.md.
class EnergyWatchJob < ApplicationJob
  queue_as :default

  def perform(now = Time.current)
    ActsAsTenant.without_tenant do
      Site.where("sites.settings->'energy'->'watch'->>'enabled' = 'true'").includes(:tenant).find_each do |site|
        ActsAsTenant.with_tenant(site.tenant) { self.class.check(site, now) }
      rescue StandardError => e
        Rails.error.report(e, handled: true)
      end
    end
  end

  # → a notificação criada (ou nil: nada fora do normal, já avisado ou na sombra).
  def self.check(site, now = Time.current)
    list = EnergyUse.anomalies(site, now: now)
    return if list.empty?

    hour = list.first["hour"]
    fmt = ->(v) { ActiveSupport::NumberHelper.number_to_rounded(v, precision: 2, strip_insignificant_zeros: true, separator: ",") }
    title = list.one? ? I18n.t("energy.watch.title_one", name: list.first["name"]) : I18n.t("energy.watch.title_many", n: list.size)
    body = list.map { |a| I18n.t("energy.watch.line", name: a["name"], kwh: fmt.(a["kwh"]), avg: fmt.(a["avg"]), hour: hour.strftime("%H:%M")) }.join("\n")
    Notifier.notify!(kind: "alerta", title: title, body: body,
                     data: { "url" => "/energia?site_id=#{site.id}", "tag" => "energia:#{site.id}", "group" => "energia",
                             "devices" => list.map { |a| a["device"].id } },
                     dedup_key: "energia:#{site.id}:#{hour.utc.iso8601}")
  rescue Shadow::Blocked
    nil
  end
end
