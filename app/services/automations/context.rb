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
  # Conjunto de pontos (Lote 4, G8, `Points::Query`): no texto
  # `{{ "tag=luz state=on" | points_where | size }}`, na expressão
  # `count_points("quality=unavailable") > 0` (e sum/min/max/avg_points).
  # Lote 5: na expressão, `trigger.id`, `trigger.value`, `trigger.data.x` e
  # `timestamp` (segundos desde 1970); no texto, `{{ "hour * 60" | calc }}`
  # calcula uma expressão (o Jinja traduzido pelo importador usa isso).
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
    # "$nome" = ponto escolhido no campo `nome` do script (F8f).
    def point(ref) = ref.is_a?(String) && ref.start_with?("$") ? points[vars[ref.delete_prefix("$")]] : points[ref]
    def value(point) = @overrides.key?(point.id) ? @overrides[point.id] : point.value

    # Valor hipotético estável: conta como "há muito tempo" (o `for` passa).
    def changed_at(point) = @overrides.key?(point.id) ? nil : point.changed_at

    # Simulação: o comando muda o valor hipotético, e as condições seguintes veem.
    def set_value(point, value) = @overrides[point.id] = value

    # Espera com `for`: quando vale a pena olhar de novo.
    def recheck!(at)
      @recheck_at = [ @recheck_at, at ].compact.min
    end

    # `locals`: variáveis do texto Liquid em volta (`assign`, item do `for`), Lote 7.
    def calc(expr, locals = {})
      expr = HaTemplates.expr(expr, site) || expr if expr.to_s.include?("{{") # ondaA1 (A9): Jinja do HA
      saved = @vars
      @vars = @vars.merge(locals) if locals.any?
      calculator = Expr.calculator(self)
      deps = calculator.dependencies(expr)
      plain(calculator.evaluate!(expr, deps.to_h { |name| [ name, variable(name) ] }))
    rescue Dentaku::Error, Dentaku::ParseError, Dentaku::TokenizerError, ZeroDivisionError, ArgumentError, TypeError => e
      raise Error, "Expressão \"#{expr.truncate(60)}\": #{e.message.truncate(120)}"
    ensure
      @vars = saved
    end

    # `defined('x')` (Lote 7, o `is defined` do HA): a variável, o caminho ou o ponto tem valor.
    def defined?(name)
      !variable(name.to_s).nil?
    rescue Error
      false
    end

    # `limit`: o pedido à IA (Lote 2) leva textos maiores que os 1000 de um aviso.
    def render(template, limit: 1000)
      return "" if template.blank?

      template = HaTemplates.text(template.to_s, site) || template # ondaA1 (A9): Jinja do HA vira Liquid
      Liquid::Template.parse(template.to_s, error_mode: :strict)
            .render!(assigns, { strict_filters: true, filters: [ Points::Query::LiquidFilter, CalcFilter ], registers: { automation_context: self } }).truncate(limit)
    rescue Liquid::Error => e
      raise Error, "Texto \"#{template.to_s.truncate(60)}\": #{e.message.truncate(120)}"
    end

    def point_text(point, v = value(point))
      ApplicationController.helpers.point_value_label(point, v)
    end

    # Pontos da consulta, com os valores desta execução (os hipotéticos na simulação).
    def query(q) = Points::Query.new(site, points: site.points.includes(:device, :area), value: method(:value), now: now).call(q)

    # Ponto como o Liquid vê (`points["k"]` e cada item do `points_where`).
    def point_drop(p)
      since = changed_at(p)
      { "key" => p.key, "name" => p.name, "value" => value(p), "text" => point_text(p), "quality" => p.quality, "unit" => p.unit, "attrs" => p.attrs,
        "device" => p.device&.name, "changed_at" => since&.in_time_zone(@zone), "since_min" => since && ((now - since) / 60).floor }
    end

    private

    def variable(name)
      return vars[name] if vars.key?(name)

      # Resposta guardada em variável (Lote 1): `agenda.count`, `resposta.action`, `http.status`.
      head, *path = name.split(".")
      return dig_var(vars[head], path, name) if path.any? && vars.key?(head)
      return dig_var(trigger, path, name) if path.any? && head == "trigger"

      builtin = { "hour" => now.hour, "minute" => now.min, "weekday" => now.wday, "day" => now.day, "month" => now.month,
                  "trigger_value" => trigger["value"], "timestamp" => now.to_i }
      return builtin[name] if builtin.key?(name)

      return attr(name) if name.include?(".attrs.")
      if name.end_with?(".changed_at") && (since = point(name.delete_suffix(".changed_at")))
        return changed_at(since)&.to_i || 0 # Lote 7: segundos desde 1970 da última mudança
      end

      p = point(name) or raise Error, "\"#{name}\" não é ponto deste local nem variável"
      v = value(p)
      raise Error, "#{p.name} está sem valor" if v.nil?

      v
    end

    # Atributo de ponto (Lote 5, G9): `sala.resumo.attrs.frase`.
    def attr(name)
      key, attr = name.split(".attrs.", 2)
      p = point(key) or raise Error, "\"#{key}\" não é ponto deste local"
      p.attrs.to_h.fetch(attr) { raise Error, "#{p.name} não tem o atributo #{attr}" }
    end

    def dig_var(value, path, name)
      v = path.reduce(value) do |o, k|
        if o.is_a?(Hash) then o[k]
        elsif o.is_a?(Array) && k.match?(/\A\d+\z/) then o[k.to_i]
        elsif o.is_a?(Array) && %w[size count].include?(k) then o.size
        end
      end
      v.nil? ? raise(Error, "\"#{name}\" está sem valor") : v
    end

    def assigns
      pts = site.points.includes(:device).to_a.to_h { |p| [ p.key, point_drop(p) ] }
      vars.merge("trigger" => trigger, "vars" => vars, "points" => pts, "site" => { "name" => site.name }, "now" => now,
                 "repeat" => { "index" => vars["repeat_index"], "item" => vars["repeat_item"] })
    end

    # Filtro Liquid `calc`: a expressão (texto) calculada nesta execução.
    module CalcFilter
      def calc(input)
        ctx = @context.registers[:automation_context] or raise Liquid::Error, "calc fora de um texto do local"
        ctx.calc(input.to_s, @context.scopes.reverse.reduce({}) { |h, s| h.merge(s) })
      rescue Error => e
        raise Liquid::Error, e.message
      end
    end

    # BigDecimal do dentaku → número simples (o estado vai para JSON).
    def plain(v)
      return v unless v.is_a?(BigDecimal) || v.is_a?(Float)

      v == v.to_i ? v.to_i : v.to_f
    end
  end
end
