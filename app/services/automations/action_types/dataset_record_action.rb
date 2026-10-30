module Automations
  module ActionTypes
    # "Registrar dados" (Lote 2, no lugar do `shell_command ia_db` do HA):
    # grava uma linha num conjunto de dados do local. Cada valor é um texto
    # Liquid (`porta: {{ trigger.point }}`); o conjunto converte pelo tipo do
    # campo (ou guarda livre). Resposta: a linha gravada {id, em, ...campos}.
    class DatasetRecordAction < Base
      describe key: "dataset_record", label: "Registrar dados",
               fields: [ f("dataset", :dataset, "Conjunto de dados", required: true),
                         f("values", :kv, "Valores (um por linha, campo: texto com {{ }})", required: true) ]
      returns "{id, em, ...campos}"

      def self.call(e, _path, node)
        dataset = e.ctx.site.datasets.find_by(id: node["dataset"]) or raise Engine::Failure, "Conjunto de dados removido do local."
        values = node["values"].to_h.transform_values { |v| e.ctx.render(v, limit: Dataset::MAX_VALUE) }
        title = "Registrar em #{dataset.name}"
        return [ title, "simulated", "Não gravado (simulação): #{values.keys.join(', ')}" ] if e.dry_run?

        record = dataset.record!(values, run: e.run)
        respond(e, node, record.row(e.ctx.now.time_zone))
        [ title, "ok", "#{values.size} campo(s)" ]
      rescue ArgumentError => ex
        raise Engine::Failure, "#{dataset&.name}: #{ex.message}"
      end
    end
  end
end
