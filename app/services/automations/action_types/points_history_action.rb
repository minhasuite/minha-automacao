module Automations
  module ActionTypes
    # "Resumo do histórico de pontos" (Lote 8; o que no HA vinha da estatística
    # longa por `shell_command`/SQLite): para cada ponto da consulta
    # (Points::Query), no período, soma o consumo em kWh por dia, conta as
    # vezes que foi para um valor ou soma o tempo ligado. Só lê: roda em sombra.
    # Resposta: {total, count, points: [{key, name, device, total, days,
    # last, median_prev, prev_days}]}, do maior para o menor total. `days` (só
    # em kWh) é do dia mais recente para trás; `median_prev` é a mediana dos
    # dias anteriores ao mais recente que tiveram consumo.
    class PointsHistoryAction < Base
      OPS = { "energy_kwh" => "Consumo (kWh)", "changes" => "Vezes que foi para o valor", "on_minutes" => "Tempo ligado (min)" }.freeze
      PERIODS = { "days" => "Últimos dias completos (até ontem)", "this_month" => "Este mês até agora", "last_month" => "Mês passado" }.freeze
      MAX_POINTS = 100

      def self.shadow_safe?(_e, _node) = true

      describe key: "points_history", label: "Resumo do histórico de pontos",
               defaults: { "op" => "energy_kwh", "period" => "days", "last_days" => 8, "response_variable" => "historico" },
               fields: [ f("query", :template, "Pontos (consulta, ex.: device_class=energy)", required: true),
                         f("op", :select, "Resumo", required: true, options: OPS), f("period", :select, "Período", required: true, options: PERIODS),
                         f("last_days", :number, "Dias (no período por dias)"), f("to", :text, "Valor (nas vezes; vazio = ligado/aberto)") ]
      returns "{total, count, points: [{key, name, device, total, days, last, median_prev, prev_days}]}"

      def self.rules(node)
        msgs = Dsl.template?(node["query"].to_s) ? [] : [ Points::Query.error(node["query"]) ].compact
        msgs << "dias de 1 a 62." if node["last_days"] && !(node["last_days"].is_a?(Integer) && node["last_days"].between?(1, 62))
        msgs
      end

      def self.call(e, _path, node)
        points = e.ctx.query(e.ctx.render(node["query"].to_s)).first(MAX_POINTS)
        from, to = bounds(node, e.ctx.now.in_time_zone(ActiveSupport::TimeZone[e.ctx.site.timezone]))
        rows = points.map { |p| row(p, node, e.ctx.site, from, to) }.sort_by { |r| -r["total"] }
        respond(e, node, { "total" => rows.sum { |r| r["total"] }.round(2), "count" => rows.size, "points" => rows })
        [ "#{OPS[node['op']]}: #{rows.size} ponto(s)", "ok", "#{I18n.l(from, format: '%d/%m %H:%M')} a #{I18n.l(to, format: '%d/%m %H:%M')}" ]
      rescue ArgumentError => ex
        raise Engine::Failure, ex.message
      end

      def self.bounds(node, now)
        case node["period"]
        when "this_month" then [ now.beginning_of_month, now ]
        when "last_month" then [ now.prev_month.beginning_of_month, now.beginning_of_month ]
        else [ now.beginning_of_day - (node["last_days"] || 8).to_i.days, now.beginning_of_day ]
        end
      end

      def self.row(p, node, site, from, to)
        base = { "key" => p.key, "name" => p.name, "device" => p.device&.name }
        case node["op"]
        when "energy_kwh" then base.merge(energy(p, site, from, to))
        when "on_minutes" then base.merge("total" => (ReadingRollup.where(point_id: p.id, bucket: "1h", starts_at: from.utc...to.utc).sum(:on_seconds) / 60.0).round(1))
        else base.merge("total" => changes(p, node["to"], from, to))
        end
      end

      def self.energy(p, site, from, to)
        per_day = Dashboards::Energy.new({}, [ p ], site).kwh_per_day(from, to)
        days = (from.to_date...to.to_date).to_a.reverse.map { |d| per_day[d].round(3) }
        prev = days.drop(1).select(&:positive?).sort
        median = prev.empty? ? 0 : (prev.size.odd? ? prev[prev.size / 2] : (prev[(prev.size / 2) - 1] + prev[prev.size / 2]) / 2.0)
        { "total" => days.sum.round(3), "days" => days, "last" => days.first || 0, "median_prev" => median.round(3), "prev_days" => prev.size }
      end

      # Vezes que o ponto foi para o valor (vazio = ligado ou aberto).
      def self.changes(p, to_value, from, to)
        scope = Reading.where(point_id: p.id, at: from.utc...to.utc)
        return scope.where(value: 1).or(scope.where(value_text: "open")).count if to_value.blank?

        scope.where(value_text: to_value.to_s).or(scope.where(value: Float(to_value, exception: false))).count
      end
    end
  end
end
