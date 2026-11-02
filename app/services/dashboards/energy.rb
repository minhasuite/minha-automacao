module Dashboards
  # Dado do widget "Consumo e custo" (`energy`, F9): serve a qualquer ponto de
  # energia, somando vários. Ponto em kWh/Wh acumulado (medidor) = diferença
  # entre os `last` das horas; ponto de potência (W/kW) = média da hora × 1 h.
  # Lê os rollups de hora (`reading_rollups`, 1h) e completa o trecho que o
  # rollup ainda não cobre com o valor atual. Tudo no fuso do local.
  #
  # Período: hoje (barras por hora), semana (seg a dom), mês ou ciclo de
  # faturamento com dia de corte (barras por dia). Tarifa: número fixo ou o
  # valor de um ponto (helper Número em R$/kWh). Meta em kWh no período.
  # ponytail: a média de potência da hora não é ponderada pelo tempo (como o
  # RollupReadingsJob) e a projeção é linear; refinar se o erro incomodar.
  class Energy
    PERIODS = { "today" => "Hoje", "week" => "Semana", "month" => "Mês", "cycle" => "Ciclo de faturamento" }.freeze

    def self.energy?(p) = p.unit.to_s.match?(/\A(k?Wh)\z/i) || p.device_class == "energy"
    def self.power?(p) = p.unit.to_s.match?(/\Ak?W\z/i) || p.device_class == "power"
    def self.supported?(p) = p.numeric? && (energy?(p) || power?(p))

    def initialize(w, points, site, tariff_point: nil, now: Time.current)
      @w = w
      @points = points.select { |p| self.class.supported?(p) }
      @zone = ActiveSupport::TimeZone[site.timezone]
      @now = now.in_time_zone(@zone)
      @tariff_point = tariff_point
    end

    def call
      from, to = bounds(@now)
      hourly = kwh_by_hour(from - 1.hour, @now)
      used = sum(hourly, from, @now)
      elapsed = @now - from
      projection = elapsed >= 1.hour ? (used / elapsed * (to - from)).round(2) : nil
      tariff = tariff_value
      cost = cost(hourly, from, @now, used)
      goal = @w["goal"].is_a?(Numeric) && @w["goal"].positive? ? @w["goal"].to_f : nil
      data = { "period" => period, "period_label" => period_label(from, to), "from" => from.iso8601, "to" => to.iso8601,
               "kwh" => used.round(2), "projection_kwh" => projection, "tariff" => tariff, "tariff_band" => (@tariff_point.attrs.to_h["band"] if tou?),
               "cost" => cost, "projection_cost" => cost && projection && (used.positive? ? (cost / used * projection).round(2) : 0.0),
               "goal" => goal, "goal_ratio" => goal && ((projection || used) / goal).round(3), "bars" => bars(hourly, from, to),
               "point_ids" => @points.map(&:id), "missing" => @points.empty? }
      compare(data, from, elapsed) if @w["compare"]
      data
    end

    # kWh por dia do local ({data → kWh}) de `from` a `to` (Lote 8: ação "Resumo do histórico de pontos").
    def kwh_per_day(from, to)
      kwh_by_hour(from - 1.hour, to).each_with_object(Hash.new(0.0)) { |(at, kwh), out| out[at.to_date] += kwh if at >= from && at < to }
    end

    private

    def period =PERIODS.key?(@w["period"]) ? @w["period"] : "month"
    def cycle_day = @w["cycle_day"].to_i.clamp(1, 28)

    # [início, fim) do período que contém `t`.
    def bounds(t)
      case period
      when "today" then [ t.beginning_of_day, t.beginning_of_day + 1.day ]
      when "week" then [ t.beginning_of_week(:monday), t.beginning_of_week(:monday) + 1.week ]
      when "cycle"
        start = t.change(day: cycle_day).beginning_of_day
        start -= 1.month if t < start
        [ start, start + 1.month ]
      else [ t.beginning_of_month, t.beginning_of_month + 1.month ]
      end
    end

    def period_label(from, to)
      return "Hoje" if period == "today"

      "#{I18n.l(from.to_date, format: '%d/%m')} a #{I18n.l((to - 1.day).to_date, format: '%d/%m')}"
    end

    # Mesmo trecho do período anterior (do início até o mesmo tempo decorrido).
    def compare(data, from, elapsed)
      prev_from = period.in?(%w[month cycle]) ? from - 1.month : from - (bounds(@now)[1] - from)
      prev = sum(kwh_by_hour(prev_from - 1.hour, prev_from + elapsed), prev_from, prev_from + elapsed)
      data["previous_kwh"] = prev.round(2)
      data["delta_pct"] = prev.positive? ? (((data["kwh"] - prev) / prev) * 100).round : nil
    end

    def tariff_value
      v = @tariff_point ? @tariff_point.value : @w["tariff"]
      v.is_a?(Numeric) && v >= 0 ? v.to_f : nil
    end

    def sum(hourly, from, to) = hourly.sum { |at, kwh| at >= from && at < to ? kwh : 0 }

    # Tarifa por horário (helper Tarifa, tarifa branca): o ponto da tarifa
    # responde `price_at` e o custo sai hora a hora; senão, kWh × preço.
    def tou? = @tariff_point&.helper_type.respond_to?(:price_at)

    def cost(hourly, from, to, kwh)
      return unless (t = tariff_value)
      return (kwh * t).round(2) unless tou?

      plugin = @tariff_point.helper_type
      hourly.sum { |at, k| at >= from && at < to ? k * plugin.price_at(@tariff_point, at) : 0 }.round(2)
    end

    public

    # Custo de `from` a `to` com a mesma tarifa do widget (ranking e comparação).
    def cost_between(from, to)
      hourly = kwh_by_hour(from - 1.hour, [ to, @now ].min)
      kwh = sum(hourly, from, to)
      [ kwh.round(3), cost(hourly, from, to, kwh) ]
    end

    private

    # {início da hora → kWh} somando os pontos, de `from` até `to` (o trecho
    # atual vem do valor do ponto).
    def kwh_by_hour(from, to)
      out = Hash.new(0.0)
      return out if @points.empty?

      rows = ReadingRollup.where(point_id: @points.map(&:id), bucket: "1h", starts_at: from.utc...to.utc).order(:starts_at).to_a.group_by(&:point_id)
      @points.each do |p|
        list = rows.fetch(p.id, [])
        energy = self.class.energy?(p)
        factor = factor(p)
        prev = nil
        list.each do |r|
          at = r.starts_at.in_time_zone(@zone)
          next if at >= @now.beginning_of_hour # a hora corrente vem do valor atual

          kwh = energy ? delta(prev&.last, r.min, r.last) : r.avg.to_f
          out[at] += kwh * factor
          prev = r
        end
        out[@now.beginning_of_hour] += live(p, prev, energy) * factor if to >= @now
      end
      out
    end

    # Diferença do acumulado; volta do medidor (zerou) conta o valor novo.
    def delta(prev_last, min, last)
      base = prev_last || min
      return 0.0 if last.nil? || base.nil?

      d = last.to_f - base.to_f
      d.negative? ? last.to_f : d
    end

    # Trecho que o rollup ainda não cobre, até agora.
    def live(p, last_row, energy)
      v = p.value
      return 0.0 unless v.is_a?(Numeric) && p.quality == "good"
      return [ v.to_f - last_row.last.to_f, 0 ].max if energy && last_row&.last
      return 0.0 if energy

      v.to_f * ((@now - @now.beginning_of_hour) / 3600.0)
    end

    # Unidade → kWh (W e Wh dividem por mil; sem unidade: energia em kWh, potência em W).
    def factor(p) = p.unit.to_s.downcase.start_with?("k") || (p.unit.blank? && self.class.energy?(p)) ? 1.0 : 0.001

    # Barras: por hora (hoje) ou por dia; as que ainda não chegaram ficam nulas.
    def bars(hourly, from, to)
      step = period == "today" ? 1.hour : 1.day
      slots = []
      t = from
      while t < to
        stop = t + step
        slots << { "at" => t.iso8601, "label" => period == "today" ? t.strftime("%H") : t.strftime("%d"),
                   "kwh" => t > @now ? nil : sum(hourly, t, stop).round(3) }
        t = stop
      end
      slots
    end
  end
end
