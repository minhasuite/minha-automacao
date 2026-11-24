# Vigia do servidor a cada minuto (ServerVitals): batimento, internet e temperatura; quedas e calor viram aviso.
class ServerWatchJob < ApplicationJob
  queue_as :default
  queue_with_priority 10

  def perform = ServerVitals.tick
end
