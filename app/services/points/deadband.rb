module Points
  # Banda morta do histórico (Reading.record!): a do ponto ou, sem ela, a
  # padrão por tipo de medida em `config/deadbands.yml` (Performance 6).
  # Tabela é dado: unidade nova = uma linha no YAML.
  module Deadband
    ACCUMULATORS = %w[total total_increasing].freeze

    module_function

    def table = @table ||= YAML.load_file(Rails.root.join("config/deadbands.yml")).transform_values { |h| h.to_h.transform_values(&:to_d) }

    # nil = grava toda mudança.
    def for(point)
      return point.deadband if point.deadband
      return unless point.capability == "measure" && point.numeric? && !ACCUMULATORS.include?(point.state_class)

      table["device_classes"][point.device_class.to_s] || table["units"][point.unit.to_s]
    end
  end
end
