module Automations
  module ActionTypes
    # "Consultar dados" (Lote 2, o `sql` do HA sem SQL): um tipo de consulta
    # (plugin de Datasets::AGGREGATES: contagem, soma, média, mínimo, máximo,
    # último, linhas) num campo, numa janela, com filtros simples ("campo =
    # valor", "campo contém x", "campo > 3", um por linha, com Liquid).
    # Resposta: {value, rows, count}: `{% for r in dados.rows %}` no pedido da IA.
    class DatasetQueryAction < Base
      # Só lê.
      def self.shadow_safe?(_e, _node) = true

      describe key: "dataset_query", label: "Consultar dados", defaults: { "op" => "rows", "limit" => 30, "response_variable" => "dados" },
               fields: [ f("dataset", :dataset, "Conjunto de dados", required: true, en: "Dataset", es: "Conjunto de datos"),
                         f("op", :select, "Consulta", required: true, options: -> { Datasets.choices }, en: "Query", es: "Consulta"),
                         f("field", :text, "Campo (contagem e linhas não precisam)", en: "Field (not needed for count and rows)", es: "Campo (conteo y filas no lo necesitan)"),
                         f("window", :duration, "Janela (ex.: 168h = 7 dias; vazio = tudo)", en: "Window (e.g. 168h = 7 days; empty = all)", es: "Ventana (ej.: 168h = 7 días; vacío = todo)"),
                         f("filters", :template, "Filtros (um por linha: campo = valor, campo contém x, campo > 3)", en: "Filters (one per line: field = value, field contains x, field > 3)", es: "Filtros (uno por línea: campo = valor, campo contiene x, campo > 3)"),
                         f("limit", :number, "Máximo de linhas (linhas)", en: "Maximum rows (rows)", es: "Máximo de filas (filas)") ]
      texts "pt-BR" => { field: "informe o campo.", limit: "máximo de linhas de 1 a %{max}." },
            en: { label: "Query data", field: "enter the field.", limit: "maximum rows from 1 to %{max}." },
            es: { label: "Consultar datos", field: "indica el campo.", limit: "máximo de filas de 1 a %{max}." }
      returns "{value, rows, count}"

      def self.rules(node)
        msgs = []
        agg = Datasets.aggregate(node["op"])
        msgs << text(:field) if agg&.needs_field? && node["field"].blank?
        msgs << text(:limit, max: Datasets::Query::MAX_ROWS) if node["limit"] && !(node["limit"].is_a?(Integer) && node["limit"].between?(1, Datasets::Query::MAX_ROWS))
        if node["filters"].is_a?(String) && !node["filters"].include?("{{")
          begin
            Datasets.parse_filters(node["filters"])
          rescue ArgumentError => e
            msgs << e.message
          end
        end
        msgs
      end

      def self.call(e, _path, node)
        dataset = e.ctx.site.datasets.find_by(id: node["dataset"]) or raise Engine::Failure, "Conjunto de dados removido do local."
        value = Datasets::Query.new(dataset, op: node["op"], field: node["field"], window_s: Dsl.seconds(node["window"]),
                                             filters: e.ctx.render(node["filters"]), limit: node["limit"], zone: e.ctx.now.time_zone).call
        rows = value.is_a?(Array) ? value : nil
        respond(e, node, { "value" => value, "rows" => rows, "count" => rows&.size }.compact)
        [ "Consultar #{dataset.name}", "ok", "#{Datasets.aggregate(node['op'])&.label}: #{rows ? "#{rows.size} linha(s)" : value.inspect.truncate(60)}" ]
      rescue ArgumentError => ex
        raise Engine::Failure, "#{dataset&.name}: #{ex.message}"
      end
    end
  end
end
