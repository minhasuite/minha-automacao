module Datasets
  # Tipos de consulta (plugins de Datasets::AGGREGATES). O campo entra no SQL
  # só como valor quotado (Arel), nunca interpolado.
  module Aggregates
    class Base
      extend PluginTexts
      translates :label

      class << self
        attr_reader :key

        def describe(key:, label:, field: false, scalar: true)
          @key = key
          @label = label
          @field = field
          @scalar = scalar
        end

        def needs_field? = @field
        def scalar? = @scalar

        # data ->> 'campo'
        def json_text(field) = Arel::Nodes::InfixOperation.new("->>", DatasetRecord.arel_table[:data], Arel::Nodes.build_quoted(field))
        def number(field) = Arel::Nodes::NamedFunction.new("CAST", [ json_text(field).as("numeric") ])
        def numeric(scope, field) = scope.where("jsonb_typeof(data -> ?) = 'number'", field)
        def plain(v) = v.is_a?(BigDecimal) ? (v == v.to_i ? v.to_i : v.to_f.round(6)) : v
      end
    end

    class Count < Base
      describe key: "count", label: "Contagem"
      texts en: { label: "Count" }, es: { label: "Conteo" }
      def self.call(scope, _field, _limit, _zone) = scope.count
    end

    # Função SQL sobre o campo numérico (soma, média, mínimo, máximo).
    class NumericFunction < Base
      def self.call(scope, field, _limit, _zone) = plain(numeric(scope, field).pick(Arel::Nodes::NamedFunction.new(@sql, [ number(field) ])))
    end

    class Sum < NumericFunction
      describe key: "sum", label: "Soma", field: true
      texts en: { label: "Sum" }, es: { label: "Suma" }
      @sql = "SUM"
      def self.call(*args) = super(*args) || 0
    end

    class Avg < NumericFunction
      describe key: "avg", label: "Média", field: true
      texts en: { label: "Average" }, es: { label: "Promedio" }
      @sql = "AVG"
    end

    class Min < NumericFunction
      describe key: "min", label: "Mínimo", field: true
      texts en: { label: "Minimum" }, es: { label: "Mínimo" }
      @sql = "MIN"
    end

    class Max < NumericFunction
      describe key: "max", label: "Máximo", field: true
      texts en: { label: "Maximum" }, es: { label: "Máximo" }
      @sql = "MAX"
    end

    # Último valor do campo (ou a última linha inteira, sem campo).
    class Last < Base
      describe key: "last", label: "Último valor"
      texts en: { label: "Latest value" }, es: { label: "Último valor" }

      def self.call(scope, field, _limit, zone)
        rec = scope.order(created_at: :desc).first or return nil
        field.present? ? rec.data[field] : rec.row(zone)
      end
    end

    class Rows < Base
      describe key: "rows", label: "Linhas (as mais recentes)", scalar: false
      texts en: { label: "Rows (most recent)" }, es: { label: "Filas (las más recientes)" }
      def self.call(scope, _field, limit, zone) = scope.order(created_at: :desc).limit(limit).map { |r| r.row(zone) }
    end
  end
end
