module Automations
  # Avalia condições e devolve [ok, checks]: cada check diz o que foi
  # testado, com quais valores e o resultado (vai para o trace). Avalia todas
  # da lista (sem atalho) para o trace mostrar o quadro inteiro.
  class Conditions
    def initialize(ctx)
      @ctx = ctx
    end

    def check(list, mode = "and")
      checks = Array(list).map { |c| one(c) }
      results = checks.pluck("result")
      ok = case mode
      when "or" then results.any?
      when "not" then results.none?
      else results.all?
      end
      [ ok, checks ]
    end

    private

    def one(c)
      ok, label, values, children = send(:"cond_#{c['type']}", c)
      { "label" => label, "result" => ok ? true : false, "values" => values, "children" => children }.compact
    rescue Context::Error => e
      { "label" => Dsl::CONDITIONS.dig(c["type"], :label) || c["type"], "result" => false, "values" => e.message }
    end

    def cond_and(c) = group(c, "Todas")
    def cond_or(c) = group(c, "Alguma")
    def cond_not(c) = group(c, "Nenhuma")

    def group(c, label)
      ok, children = check(c["conditions"], c["type"])
      [ ok, "#{label} destas", nil, children ]
    end

    def cond_state(c)
      p = point!(c["point"])
      v = @ctx.value(p)
      ok = true
      parts = []
      if c.key?("is")
        ok &&= v == c["is"]
        parts << "está #{label(p, c['is'])}"
      end
      if c["quality"]
        ok &&= p.quality == c["quality"]
        parts << "situação #{Dsl::QUALITIES.fetch(c['quality'], c['quality']).downcase}"
      end
      ok = held?(p, c["for"]) && ok if c["for"]
      parts << "há #{Dsl.duration_label(Dsl.seconds(c['for']))}" if c["for"]
      [ ok, "#{p.name} #{parts.join(', ')}", "agora: #{@ctx.point_text(p, v)}#{", #{Dsl::QUALITIES[p.quality].downcase}" if p.quality != 'good'}" ]
    end

    def cond_numeric(c)
      p = point!(c["point"])
      v = @ctx.value(p)
      ok = v.is_a?(Numeric) && (c["above"].nil? || v > c["above"]) && (c["below"].nil? || v < c["below"])
      [ ok, "#{p.name} #{range_label(c)}", "agora: #{@ctx.point_text(p, v)}" ]
    end

    def cond_time(c)
      now = @ctx.now
      t = now.strftime("%H:%M")
      ok = window?(t, c["after"], c["before"]) && day?(now, c["days"])
      label = [ ("depois de #{c['after']}" if c["after"]), ("antes de #{c['before']}" if c["before"]), days_label(c["days"]) ].compact.join(", ")
      [ ok, "Horário #{label}", "agora: #{t}, #{Dsl::DAYS[now.wday].downcase}" ]
    end

    def cond_sun(c)
      site = @ctx.site
      raise Context::Error, "O local precisa de latitude e longitude." unless site.latitude && site.longitude

      now = @ctx.now
      at = ->(ev, off) { ev && Sun.at(ev, now.to_date, site.latitude, site.longitude, now.time_zone)&.+(Dsl.seconds(off).to_i) }
      after = at.call(c["after"], c["after_offset"])
      before = at.call(c["before"], c["before_offset"])
      ok = window?(now, after, before)
      fmt = ->(x) { x&.in_time_zone(now.time_zone)&.strftime("%H:%M") }
      label = [ ("depois do #{Dsl::SUN_EVENTS[c['after']].downcase} (#{fmt.call(after)})" if c["after"]),
                ("antes do #{Dsl::SUN_EVENTS[c['before']].downcase} (#{fmt.call(before)})" if c["before"]) ].compact.join(" e ")
      [ ok, "Sol: #{label}", "agora: #{now.strftime('%H:%M')}" ]
    end

    def cond_expr(c)
      r = @ctx.calc(c["expr"])
      [ r == true || (r.is_a?(Numeric) && r.nonzero?), c["expr"], "resultado: #{r.inspect}" ]
    end

    # Janela que pode virar a meia-noite (18:00 → 05:00).
    def window?(x, after, before)
      return x >= after || x < before if after && before && after > before

      (after.nil? || x >= after) && (before.nil? || x < before)
    end

    def day?(now, days) = days.nil? || days.include?(now.wday)
    def days_label(days) = days && (days.size == 7 ? nil : days.map { |d| Dsl::DAYS[d] }.join("/"))

    def held?(point, duration)
      need = Dsl.seconds(duration).to_i
      since = @ctx.changed_at(point)
      return true if since.nil? || since <= @ctx.now - need

      @ctx.recheck!(since + need)
      false
    end

    def point!(id) = @ctx.point(id) || raise(Context::Error, "Ponto removido do local.")
    def label(p, v) = ApplicationController.helpers.point_value_label(p, v)

    def range_label(c)
      [ ("acima de #{c['above']}" if c["above"]), ("abaixo de #{c['below']}" if c["below"]) ].compact.join(" e ")
    end
  end
end
