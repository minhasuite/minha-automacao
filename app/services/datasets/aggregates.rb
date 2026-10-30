module Datasets
  # Tipos de consulta (plugins de Datasets::AGGREGATES). O campo entra no SQL
  # só como valor quotado (Arel), nunca interpolado.
  module Aggregates
    class Base
      class << self
        attr_reader :key, :label

        def describe(key:, label:, field: false, scalar: true)
          @key = key
          @label = label
          @field = field
          @scalar = scalar
        end

        def needs_field? = @field
        def scalar? = @scalar

        # data ->> 'campo'
        def text(field) = Arel::Nodes::InfixOperation.new("->>", DatasetRecord.arel_table[:data], Arel::Nodes.build_quoted(field))
        def number(field) = Arel::Nodes::NamedFunction.new("CAST", [ text(field).as("numeric") ])
        def numeric(scope, field) = scope.where("jsonb_typeof(data -> ?) = 'number'", field)
        def plain(v) = v.is_a?(BigDecimal) ? (v == v.to_i ? v.to_i : v.to_f.round(6)) : v
      end
    end

    class Count < Base
      describe key: "count", label: "Contagem"
      def self.call(scope, _field, _limit, _zone) = scope.count
    end

    # Função SQL sobre o campo numérico (soma, média, mínimo, máximo).
    class NumericFunction < Base
      def self.call(scope, field, _limit, _zone) = plain(numeric(scope, field).pick(Arel::Nodes::NamedFunction.new(@sql, [ number(field) ])))
    end

    class Sum < NumericFunction
      describe key: "sum", label: "Soma", field: true
      @sql = "SUM"
      def self.call(*args) = super(*args) || 0
    end

    class Avg < NumericFunction
      describe key: "avg", label: "Média", field: true
      @sql = "AVG"
    end

    class Min < NumericFunction
      describe key: "min", label: "Mínimo", field: true
      @sql = "MIN"
    end

    class Max < NumericFunction
      describe key: "max", label: "Máximo", field: true
      @sql = "MAX"
    end

    # Último valor do campo (ou a última linha inteira, sem campo).
    class Last < Base
      describe key: "last", label: "Último valor"

      def self.call(scope, field, _limit, zone)
        rec = scope.order(created_at: :desc).first or return nil
        field.present? ? rec.data[field] : rec.row(zone)
      end
    end

    class Rows < Base
      describe key: "rows", label: "Linhas (as mais recentes)", scalar: false
      def self.call(scope, _field, limit, zone) = scope.order(created_at: :desc).limit(limit).map { |r| r.row(zone) }
    end
  end
end
