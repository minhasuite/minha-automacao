module Automations
  # Avalia condições e devolve [ok, checks]: cada check diz o que foi
  # testado, com quais valores e o resultado (vai para o trace). Avalia todas
  # da lista (sem atalho) para o trace mostrar o quadro inteiro. Cada tipo é
  # um plugin de ConditionTypes; aqui ficam os auxiliares que eles usam.
  class Conditions
    attr_reader :ctx

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

    # Janela que pode virar a meia-noite (18:00 → 05:00).
    def window?(x, after, before)
      return x >= after || x < before if after && before && after > before

      (after.nil? || x >= after) && (before.nil? || x < before)
    end

    def held?(point, duration)
      need = Dsl.seconds(duration).to_i
      since = @ctx.changed_at(point)
      return true if since.nil? || since <= @ctx.now - need

      @ctx.recheck!(since + need)
      false
    end

    def point!(id) = @ctx.point(id) || raise(Context::Error, "Ponto removido do local.")
    def label(p, v) = ApplicationController.helpers.point_value_label(p, v)

    private

    def one(c)
      plugin = ConditionTypes[c["type"]] or raise Context::Error, "Condição desconhecida: #{c['type']}"
      ok, label, values, children = plugin.check(self, c)
      { "label" => label, "result" => ok ? true : false, "values" => values, "children" => children }.compact
    rescue Context::Error => e
      { "label" => ConditionTypes[c["type"]]&.label || c["type"], "result" => false, "values" => e.message }
    end
  end
end
