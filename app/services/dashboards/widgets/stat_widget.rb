module Dashboards
  module Widgets
    # Contador ou número (F5; também o tipo dos selos): `query` ou `bind` e
    # `aggregate`; com `bind` e `attribute` (Lote 5), o atributo do ponto.
    # `aggregate: "change"` + `period` (day/week/month/year; o card statistic
    # do HA): quanto o ponto subiu desde o começo do período, pelo histórico.
    class StatWidget < Base
      describe type: "stat", label: "Contador / número", icon: "calculator", params: %w[aggregate attribute period], bind: true

      def self.permit = [ *params, { labels: Facts::LABEL_FORMS } ]
      texts en: { label: "Counter / number" },
            es: { label: "Contador / número" }


      def self.data(r, w, binds)
        list = w["query"] ? r.query(w["query"]) : binds
        agg = w["aggregate"] || (w["query"] ? "count" : "last")
        # Soma e média são "agora": leitura de aparelho sem sinal não entra (senão "0 W agora" com tudo fora do ar).
        nums = list.select { |p| agg == "count" || p.quality == "good" }.map(&:value).grep(Numeric)
        value = case agg
        when "count" then list.size
        when "sum" then nums.any? ? nums.sum.round(2) : nil
        when "avg" then nums.any? ? (nums.sum / nums.size).round(2) : nil
        when "min" then nums.min
        when "max" then nums.max
        when "change" then change(list.first, w["period"], r.site)
        else list.first&.value
        end
        unit = agg == "count" ? nil : list.filter_map(&:unit).first
        text = w["attribute"].present? && agg == "last" ? list.first&.attrs.to_h[w["attribute"]].to_s.presence || "—" : value_text(value, unit, agg, list.first)
        [ { "value" => value, "unit" => unit, "text" => text, "point_ids" => list.first(Resolver::LIST_LIMIT).map(&:id),
            "caption" => caption(w, value, text), "drill_url" => (drill_url(r, w) if w["query"]) }.compact,
          w["query"] ? r.query(w["query"], with_state: false) : [] ]
      end

      # P1.4: rótulo do selo/contador pela contagem (`labels` {zero, one, other}; `%{count}` = o número). Sem
      # `labels`, nil: a tela mostra "número rótulo" como sempre, sem inventar singular.
      def self.caption(w, value, text)
        forms = w["labels"].is_a?(Hash) ? w["labels"].slice(*Facts::LABEL_FORMS).compact_blank : {}
        return nil if forms.empty? || value.nil?

        n = value.is_a?(Numeric) ? value : 1
        pick = n.zero? ? forms["zero"] || forms["other"] : (n == 1 ? forms["one"] || forms["other"] : forms["other"])
        pick&.gsub("%{count}", text.to_s)&.squish
      end

      def self.errors(w)
        e = w["bind"].blank? && w["query"].blank? ? [ "stat precisa de bind ou query" ] : []
        e << I18n.t("dashboards.schema.labels", forms: Facts::LABEL_FORMS.join(", ")) if w.key?("labels") &&
                                                                                       !(w["labels"].is_a?(Hash) && (w["labels"].keys - Facts::LABEL_FORMS).empty? && w["labels"].values.all?(String))
        e
      end

      # Ideia 14: os pontos que entram no número (só com consulta).
      def self.drill(r, w, _key)
        return nil unless w["query"]

        { "title" => w["label"].presence || I18n.t("dashboards.drill.title"), "points" => r.query(w["query"]) }
      end

      # Valor agora − o do começo do período (a última leitura antes dele, ou a primeira depois); nil sem histórico.
      def self.change(point, period, site)
        return nil unless point && point.value.is_a?(Numeric)

        start = Time.current.in_time_zone(site.timezone).public_send(:"beginning_of_#{period.presence_in(Schema::PERIODS) || 'day'}")
        base = Reading.where(point_id: point.id, at: ...start).order(at: :desc).limit(1).pick(:value) ||
               Reading.where(point_id: point.id, at: start..).order(:at).limit(1).pick(:value)
        base && (point.value - base).round(2)
      end

      def self.value_text(value, unit, agg, first)
        helpers = ApplicationController.helpers
        return helpers.point_value_text(first) if agg == "last" && first
        return "—" if value.nil?

        [ helpers.number_with_precision(value, precision: 1, strip_insignificant_zeros: true, delimiter: I18n.t("number.format.delimiter")), unit ].compact.join(" ")
      end

      def self.attrs(p, _site = nil)
        query = QueryListWidget.query(p)
        labels = Facts::LABEL_FORMS.index_with { |k| p.dig(:labels, k).to_s.strip }.compact_blank.presence
        return { "query" => query, "aggregate" => p[:aggregate].presence, "labels" => labels }.compact if query.any?

        # Lote 5 (G9): atributo do ponto
        agg = p[:aggregate] == "count" ? "last" : p[:aggregate].presence
        { "bind" => p[:bind].presence, "aggregate" => agg, "attribute" => p[:attribute].presence,
          "period" => (p[:period].presence_in(Schema::PERIODS) if agg == "change") }
      end

      def self.form = %w[web/dashboards/widget_forms/query web/dashboards/widget_forms/stat]
    end
  end
end
