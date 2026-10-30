# "Atualizar agora" na página do dispositivo: uma leitura (só leitura) fora da vez.
class PollDeviceJob < ApplicationJob
  queue_as :default

  def perform(device_id) = Polling.poll_device(device_id)
end
