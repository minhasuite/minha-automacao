# Evento "system_started" em cada local (Lote 5, G7): o supervisor do Solid
# Queue enfileira ao subir (config/initializers/tuya_listener.rb).
class SystemStartedJob < ApplicationJob
  queue_as :default

  def perform = Automations::Triggers.system_started!
end
