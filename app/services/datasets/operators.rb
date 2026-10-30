module Datasets
  # Operadores de filtro (plugins de Datasets::OPERATORS): "campo = valor",
  # "campo contém x", "campo > 3". Comparação com número só pega campo
  # numérico; com texto (ex.: data ISO), compara como texto.
  module Operators
    class Base
      class << self
        attr_reader :symbol

        def describe(symbol:) = @symbol = symbol
        def number(value) = Float(value.to_s.tr(",", "."), exception: false)
      end
    end

    class Eq < Base
      describe symbol: "="
      def self.apply(scope, field, value) = scope.where("data ->> ? = ?", field, value)
    end

    class NotEq < Base
      describe symbol: "!="
      def self.apply(scope, field, value) = scope.where("data ->> ? IS DISTINCT FROM ?", field, value)
    end

    class Contains < Base
      describe symbol: "contém"
      def self.apply(scope, field, value) = scope.where("data ->> ? ILIKE ?", field, "%#{DatasetRecord.sanitize_sql_like(value)}%")
    end

    # Maior/menor: o SQL é constante de cada classe, nunca vem do usuário.
    class Compare < Base
      def self.apply(scope, field, value)
        if (n = number(value))
          scope.where(self::NUM, field, field, n)
        else
          scope.where(self::TXT, field, value)
        end
      end
    end

    class Gt < Compare
      NUM = "jsonb_typeof(data -> ?) = 'number' AND (data ->> ?)::numeric > ?".freeze
      TXT = "data ->> ? > ?".freeze
      describe symbol: ">"
    end

    class Lt < Compare
      NUM = "jsonb_typeof(data -> ?) = 'number' AND (data ->> ?)::numeric < ?".freeze
      TXT = "data ->> ? < ?".freeze
      describe symbol: "<"
    end

    class Gte < Compare
      NUM = "jsonb_typeof(data -> ?) = 'number' AND (data ->> ?)::numeric >= ?".freeze
      TXT = "data ->> ? >= ?".freeze
      describe symbol: ">="
    end

    class Lte < Compare
      NUM = "jsonb_typeof(data -> ?) = 'number' AND (data ->> ?)::numeric <= ?".freeze
      TXT = "data ->> ? <= ?".freeze
      describe symbol: "<="
    end
  end
end
