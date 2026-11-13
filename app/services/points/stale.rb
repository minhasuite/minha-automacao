module Points
  # Sensor de abertura parado em "aberto" há tempo demais vira "desatualizado"
  # (qualidade `stale`) com um aviso só, em vez de o escalonamento repetir por
  # horas um estado em que ninguém confia (10/11/2026: o "fechou" do portão se
  # perdeu antes da nuvem). Liga por ponto: `address.stale_open_s` (formulário
  # do ponto, em minutos). O valor continua o mesmo; volta a "bom" quando o
  # aparelho manda valor novo (ou no "Redefinir estado"). Releitura com o mesmo
  # valor não tira o "desatualizado" (`Point#report!` pergunta aqui).
  # Automação que não deve agir sobre ele usa a condição "Ponto está" com a
  # situação "Bom".
  module Stale
    def self.limit(point) = point.address["stale_open_s"].to_i.positive? ? point.address["stale_open_s"].to_i : nil

    def self.due?(point, now = Time.current)
      s = limit(point) or return false
      point.value == true && point.changed_at.present? && point.changed_at <= now - s
    end

    # RunSchedulesJob (a cada minuto). Poucos pontos têm o limite: filtra no banco pelo endereço.
    def self.tick(now = Time.current)
      points = ActsAsTenant.without_tenant { Point.where("(address->>'stale_open_s') IS NOT NULL").where(quality: "good").to_a }
      points.each do |point|
        next unless due?(point, now)

        ActsAsTenant.with_tenant(point.tenant) do
          point.report!(point.value, quality: "stale", at: now)
          notify(point)
        end
      rescue StandardError => e
        Rails.error.report(e, handled: true)
      end
    end

    def self.notify(point)
      I18n.with_locale(I18n.default_locale) do
        Notifier.notify!(kind: "alerta", title: I18n.t("points.stale.title", name: point.name),
                         body: I18n.t("points.stale.body", since: I18n.l(point.changed_at.in_time_zone(point.site.timezone), format: :short)),
                         data: { "url" => "/pontos/#{point.id}", "tag" => "stale:#{point.id}", "point_id" => point.id,
                                 "site_id" => point.site_id, "priority" => "high" },
                         dedup_key: "stale:#{point.id}:#{point.changed_at.to_i}")
      end
    rescue Shadow::Blocked
      nil
    end
  end
end
