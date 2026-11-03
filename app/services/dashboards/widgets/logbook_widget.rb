module Dashboards
  module Widgets
    # Diário (ondaB2 B10; o `logbook` do HA): as últimas linhas do Diário dos
    # pontos escolhidos (ou do local inteiro), pelas mesmas fontes e o mesmo
    # corte de papel da tela Diário.
    class LogbookWidget < Base
      LIMITS = 3..30
      describe type: "logbook", label: "Diário", icon: "view-list", params: %w[period limit], binds: true
      texts en: { label: "Logbook", empty: "Nothing in the period.", bad: "period is 24h, 7d or 30d and limit goes from 3 to 30" },
            es: { label: "Diario", empty: "Nada en el período.", bad: "period es 24h, 7d o 30d y limit va de 3 a 30" },
            "pt-BR" => { empty: "Nada no período.", bad: "period é 24h, 7d ou 30d e limit vai de 3 a 30" }

      def self.errors(w)
        bad = (w.key?("limit") && !LIMITS.cover?(w["limit"])) || (w.key?("period") && !Logbook::PERIODS.key?(w["period"]))
        bad ? [ text(:bad) ] : []
      end

      def self.attrs(p, site = nil) = super.merge("limit" => number(p[:limit])&.to_i).compact
      def self.form = "web/dashboards/widget_forms/cards"

      def self.data(r, w, binds)
        limit = w["limit"] || 10
        params = { period: w["period"] || "24h" }
        filters = (binds.presence || [ nil ]).map { |p| Logbook::Filter.new(site: r.site, role: r.role, params: params.merge(point_id: p&.id).compact, limit: limit) }
        items = filters.flat_map { |f| Logbook.call(f).first }.uniq.sort_by { |i| -i.at.to_f }.first(limit)
        [ { "point_ids" => binds.map(&:id), "items" => items.map { |i| i.as_json.slice("at", "icon", "tone", "title", "state", "detail", "user") }, "empty" => text(:empty) }, [] ]
      end
    end
  end
end
