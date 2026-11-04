module Drivers
  # Ponto sem aparelho: o valor do comando vira o valor do ponto. Helper
  # (F8e) entrega ao plugin (temporizador agenda, grupo repassa aos membros).
  # Ponto de script (F8f) executa o script; o de automação liga ou desliga ela.
  class Virtual
    def execute(point, command, value)
      return Scripts.execute(point, value) if point.capability == "script"
      return AutomationPoints.execute(point, command, value) if AutomationPoints.automation?(point)

      plugin = point.helper_type
      return plugin.execute(point, command, value) if plugin

      point.report!(Points::Command.new(point, command, value).new_value)
    end
  end
end
