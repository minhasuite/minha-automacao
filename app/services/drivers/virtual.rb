module Drivers
  # Ponto sem aparelho (helper do HA): o valor do comando vira o valor do ponto.
  class Virtual
    def execute(point, command, value)
      point.report!(Points::Command.new(point, command, value).new_value)
    end
  end
end
