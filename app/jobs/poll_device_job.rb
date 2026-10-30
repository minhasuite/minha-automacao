# "Atualizar agora" na página do dispositivo: uma leitura (só leitura) fora da vez.
class PollDeviceJob < ApplicationJob
  queue_as :default

  def perform(device_id, reconnect: false) = Polling.poll_device(device_id, reconnect: reconnect)
end
