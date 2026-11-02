module Datasets
  # Uma consulta num conjunto: tipo (plugin de AGGREGATES), campo, janela
  # (segundos até agora; nil = tudo), filtros em texto e máximo de linhas.
  class Query
    MAX_ROWS = 500

    def initialize(dataset, op:, field: nil, window_s: nil, filters: nil, limit: nil, zone: Time.zone)
      @dataset = dataset
      @aggregate = Datasets.aggregate(op) or raise ArgumentError, I18n.t("datasets.errors.no_query", op: op)
      @field = field.to_s.strip.presence
      @window_s = window_s.to_i
      @filters = filters
      @limit = (limit || 30).to_i.clamp(1, MAX_ROWS)
      @zone = zone
      raise ArgumentError, I18n.t("datasets.errors.no_field") if @aggregate.needs_field? && @field.nil?
    end

    def scope
      s = @dataset.records
      s = s.where(created_at: (Time.current - @window_s)..) if @window_s.positive?
      Datasets.parse_filters(@filters).reduce(s) { |acc, (op, field, value)| op.apply(acc, field, value) }
    end

    def call = @aggregate.call(scope, @field, @limit, @zone)
  end
end
