module Automations
  # O mundo visto por uma execução: valores dos pontos (os de verdade ou os
  # hipotéticos da simulação), a hora no fuso do local, as variáveis e o
  # gatilho. Avalia as expressões (dentaku, sem código arbitrário) e monta os
  # textos (Liquid, só com os objetos daqui).
  #
  # Expressão: pontos pela `key` (`sala.temperatura > 28`), variáveis pelo
  # nome, e `hour`, `minute`, `weekday` (0 = domingo), `day`, `month`,
  # `trigger_value`. Texto: `{{ trigger.point }}`, `{{ trigger.value }}`,
  # `{{ trigger.data.x }}` (webhook), `{{ points["sala.luz"].text }}` (também
  # `.value`, `.quality`, `.changed_at` e `.since_min`, minutos no valor),
  # `{{ site.name }}`, `{{ now | date: "%H:%M" }}` e as variáveis pelo nome.
  class Context
    class Error < StandardError; end

    attr_reader :site, :vars, :trigger, :recheck_at

    # `overrides`: {key ou id do ponto => valor} (simulação). `at`: hora
    # hipotética (simulação); sem ela, a hora corre de verdade.
    def initialize(site:, trigger: {}, vars: {}, overrides: {}, at: nil)
      @site = site
      @trigger = trigger.to_h.stringify_keys
      @vars = vars.to_h.stringify_keys
      @zone = ActiveSupport::TimeZone[site.timezone]
      @at = at
      @overrides = overrides.to_h.each_with_object({}) do |(ref, v), h|
        p = point(ref.to_s) or next
        h[p.id] = v.is_a?(String) ? p.cast(v) : v
      end
    end

    def now = (@at || Time.current).in_time_zone(@zone)
    def points = @points ||= site.points.to_a.each_with_object({}) { |p, h| h[p.id] = h[p.key] = p }
    def point(ref) = points[ref]
    def value(point) = @overrides.key?(point.id) ? @overrides[point.id] : point.value

    # Valor hipotético estável: conta como "há muito tempo" (o `for` passa).
    def changed_at(point) = @overrides.key?(point.id) ? nil : point.changed_at

    # Simulação: o comando muda o valor hipotético, e as condições seguintes veem.
    def set_value(point, value) = @overrides[point.id] = value

    # Espera com `for`: quando vale a pena olhar de novo.
    def recheck!(at)
      @recheck_at = [ @recheck_at, at ].compact.min
    end

    def calc(expr)
      calculator = Expr.calculator
      deps = calculator.dependencies(expr)
      plain(calculator.evaluate!(expr, deps.to_h { |name| [ name, variable(name) ] }))
    rescue Dentaku::Error, Dentaku::ParseError, Dentaku::TokenizerError, ZeroDivisionError, ArgumentError, TypeError => e
      raise Error, "Expressão \"#{expr.truncate(60)}\": #{e.message.truncate(120)}"
    end

    def render(template)
      return "" if template.blank?

      Liquid::Template.parse(template.to_s, error_mode: :strict).render!(assigns, { strict_filters: true }).truncate(1000)
    rescue Liquid::Error => e
      raise Error, "Texto \"#{template.to_s.truncate(60)}\": #{e.message.truncate(120)}"
    end

    def point_text(point, v = value(point))
      ApplicationController.helpers.point_value_label(point, v)
    end

    private

    def variable(name)
      return vars[name] if vars.key?(name)

      builtin = { "hour" => now.hour, "minute" => now.min, "weekday" => now.wday, "day" => now.day, "month" => now.month,
                  "trigger_value" => trigger["value"] }
      return builtin[name] if builtin.key?(name)

      p = point(name) or raise Error, "\"#{name}\" não é ponto deste local nem variável"
      v = value(p)
      raise Error, "#{p.name} está sem valor" if v.nil?

      v
    end

    def assigns
      pts = site.points.to_a.to_h do |p|
        since = changed_at(p)
        [ p.key, { "name" => p.name, "value" => value(p), "text" => point_text(p), "quality" => p.quality,
                   "changed_at" => since&.in_time_zone(@zone), "since_min" => since && ((now - since) / 60).floor } ]
      end
      vars.merge("trigger" => trigger, "vars" => vars, "points" => pts, "site" => { "name" => site.name }, "now" => now,
                 "repeat" => { "index" => vars["repeat_index"] })
    end

    # BigDecimal do dentaku → número simples (o estado vai para JSON).
    def plain(v)
      return v unless v.is_a?(BigDecimal) || v.is_a?(Float)

      v == v.to_i ? v.to_i : v.to_f
    end
  end
end
