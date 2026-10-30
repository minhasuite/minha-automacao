module HelperTypes
  # Consulta (Lote 2, o sensor `sql` do HA sem SQL): contagem, soma, média,
  # mínimo, máximo ou último valor de um campo num conjunto de dados, numa
  # janela e com filtros simples. Vira ponto: vai para painel e automação.
  # Refaz a cada linha gravada no conjunto (`sources` = id do conjunto).
  # ponytail: numa janela parada, a linha velha não "sai" sozinha até a
  # próxima gravação (igual à Estatística); refazer pelo relógio se precisar.
  class DatasetQuery < Plugin
    describe key: "dataset_query", title: "Consulta", icon: "table", capability: "measure",
             description: "Contagem, soma, média, mínimo, máximo ou último valor de um campo num conjunto de dados: portões abertos hoje."
    fields %i[dataset op field window filters]

    def self.assign(point, form)
      dataset = point.site.datasets.find_by(id: form["dataset"].presence || point.address.dig("sources", 0))
      return point.errors.add(:base, "Escolha o conjunto de dados.") unless dataset

      op = form["op"].presence || point.address["op"]
      aggregate = Datasets.aggregate(op)
      return point.errors.add(:base, "Escolha a consulta.") unless aggregate&.scalar?

      field = (form.key?("field") ? form["field"] : point.address["field"]).to_s.strip.presence
      return point.errors.add(:base, "Informe o campo.") if aggregate.needs_field? && field.nil?

      raw_window = form.key?("window") ? form["window"].to_s.strip : point.address["window_s"].to_s
      window = raw_window.empty? ? nil : Automations::Dsl.seconds(raw_window)
      return point.errors.add(:base, "Janela inválida (use 1h, 24h, 168h; vazio = tudo).") if raw_window.present? && !window&.positive?

      filters = form.key?("filters") ? form["filters"].to_s.strip : point.address["filters"].to_s
      begin
        Datasets.parse_filters(filters)
      rescue ArgumentError => e
        return point.errors.add(:base, e.message.upcase_first)
      end

      # Último valor de campo de texto vira ponto de texto; o resto é número.
      text = aggregate.key == "last" && dataset.field_type(field) != "number" && !dataset.free?
      point.capability = text ? "text" : "measure"
      point.data_type = Point::CAPABILITIES[point.capability]
      point.writable = false
      point.address = point.address.merge("sources" => [ dataset.id ], "op" => aggregate.key, "field" => field, "window_s" => window, "filters" => filters.presence)
    end

    def self.sourced? = true

    def self.refresh!(point)
      dataset = point.site.datasets.find_by(id: point.address.dig("sources", 0)) or return point.report!(nil, quality: "unavailable")

      a = point.address
      v = Datasets::Query.new(dataset, op: a["op"], field: a["field"], window_s: a["window_s"], filters: a["filters"]).call
      point.report!(point.capability == "text" ? v&.to_s : v)
    rescue ArgumentError, ActiveRecord::StatementInvalid => e
      Rails.logger.info("[helpers] #{point.key}: #{e.message.truncate(120)}")
      point.report!(point.value, quality: "error")
    end

    def self.summary(point)
      a = point.address
      [ Datasets.aggregate(a["op"])&.label, a["field"], (Automations::Dsl.duration_label(a["window_s"].to_i) if a["window_s"]) ].compact.join(" · ")
    end
  end
end
