module Drivers
  # Ponto sem aparelho: o valor do comando vira o valor do ponto. Helper
  # (F8e) entrega ao plugin (temporizador agenda, grupo repassa aos membros).
  class Virtual
    def execute(point, command, value)
      plugin = point.helper_type
      return plugin.execute(point, command, value) if plugin

      point.report!(Points::Command.new(point, command, value).new_value)
    end
  end
end
