# "Sincronizar agora" e a primeira varredura depois do login: varre a conta
# pela fila (a Tuya faz 3 pedidos por aparelho).
class SyncIntegrationJob < ApplicationJob
  queue_as :default

  def perform(integration_id) = Polling.poll_integration(integration_id)
end
