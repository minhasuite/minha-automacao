module Dashboards
  module Widgets
    # Contador ou número (F5; também o tipo dos selos): `query` ou `bind` e
    # `aggregate`; com `bind` e `attribute` (Lote 5), o atributo do ponto.
    # `aggregate: "change"` + `period` (day/week/month/year; o card statistic
    # do HA): quanto o ponto subiu desde o começo do período, pelo histórico.
    class StatWidget < Base
      describe type: "stat", label: "Contador / número", icon: "calculator", params: %w[aggregate attribute period], bind: true
      texts en: { label: "Counter / number" },
            es: { label: "Contador / número" }

      def self.errors(w) = w["bind"].blank? && w["query"].blank? ? [ "stat precisa de bind ou query" ] : []

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
        [ { "value" => value, "unit" => unit, "text" => text, "point_ids" => list.first(Resolver::LIST_LIMIT).map(&:id) },
          w["query"] ? r.query(w["query"], with_state: false) : [] ]
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
        return { "query" => query, "aggregate" => p[:aggregate].presence } if query.any?

        # Lote 5 (G9): atributo do ponto
        agg = p[:aggregate] == "count" ? "last" : p[:aggregate].presence
        { "bind" => p[:bind].presence, "aggregate" => agg, "attribute" => p[:attribute].presence,
          "period" => (p[:period].presence_in(Schema::PERIODS) if agg == "change") }
      end

      def self.form = %w[web/dashboards/widget_forms/query web/dashboards/widget_forms/stat]
    end
  end
end
