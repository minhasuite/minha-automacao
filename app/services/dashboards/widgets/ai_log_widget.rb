module Dashboards
  module Widgets
    # Linha do tempo da IA (o `linha_do_tempo` do HA): as últimas chamadas à IA do local, no formato do
    # Diário (hora, ícone tonal, título, estado em pílula e detalhe), então a web e o app desenham com o
    # mesmo Logbook. O título é a automação (ou a origem: pergunta, voz, teste); o detalhe, o modelo e os
    # tokens. Nunca o prompt nem a resposta (o AiCall não guarda).
    class AiLogWidget < Base
      LIMITS = 3..30
      TONES = { "ok" => "success", "error" => "danger", "blocked" => "warn" }.freeze
      describe type: "ai_log", label: "Linha do tempo da IA", icon: "sparkles", params: %w[limit]
      texts en: { label: "AI timeline", empty: "No AI calls yet.", bad: "limit goes from 3 to 30" },
            es: { label: "Línea de tiempo de la IA", empty: "Todavía no hay llamadas a la IA.", bad: "limit va de 3 a 30" },
            "pt-BR" => { empty: "Nenhuma chamada à IA ainda.", bad: "limit vai de 3 a 30" }

      def self.errors(w) = w.key?("limit") && !LIMITS.cover?(w["limit"]) ? [ text(:bad) ] : []
      def self.attrs(p, site = nil) = super.merge("limit" => number(p[:limit])&.to_i).compact
      def self.form = "web/dashboards/widget_forms/cards"

      def self.data(r, w, _binds)
        calls = AiCall.where(site_id: [ r.site.id, nil ]).order(created_at: :desc).limit(w["limit"] || 8).includes(:automation).to_a
        items = calls.map do |c|
          { "at" => c.created_at.iso8601, "icon" => c.status == "ok" ? "sparkles" : "exclamation-circle", "tone" => TONES.fetch(c.status, "neutral"),
            "title" => c.automation&.name || c.source_label, "state" => c.status_label,
            "detail" => [ c.model, ("#{c.tokens} tokens" if c.tokens.positive?), (c.error.to_s.truncate(80) if c.status == "error") ].compact_blank.join(" · ") }
        end
        [ { "items" => items, "empty" => text(:empty) }, [] ]
      end
    end
  end
end
