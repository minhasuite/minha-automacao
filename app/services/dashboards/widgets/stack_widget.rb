module Dashboards
  module Widgets
    # Pilha e grade (ondaB2 B8; vertical-stack, horizontal-stack e grid do HA):
    # outros widgets dentro, em `widgets` (até 12, dois níveis). Cada um
    # mantém o próprio quadro de tempo real; a pilha só arruma o desenho.
    class StackWidget < Base
      DIRECTIONS = %w[vertical horizontal grid].freeze
      describe type: "stack", label: "Pilha ou grade", icon: "collection", params: %w[direction columns]
      texts en: { label: "Stack or grid", bad: "direction is vertical, horizontal or grid and columns goes from 2 to 4" },
            es: { label: "Pila o cuadrícula", bad: "direction es vertical, horizontal o grid y columns va de 2 a 4" },
            "pt-BR" => { bad: "direction é vertical, horizontal ou grid e columns vai de 2 a 4" }

      def self.container? = true
      def self.form = "web/dashboards/widget_forms/stack"
      def self.attrs(p, site = nil) = super.merge("columns" => number(p[:columns])&.to_i).compact

      def self.errors(w)
        bad = (w.key?("direction") && !DIRECTIONS.include?(w["direction"])) || (w.key?("columns") && !(2..4).cover?(w["columns"]))
        bad ? [ text(:bad) ] : []
      end
    end
  end
end
