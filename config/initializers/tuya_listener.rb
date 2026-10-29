# Ouvinte Tuya (Tuya::Listener) no processo worker do Solid Queue. Sem
# aparelho com `listen` ligado (VPS, padrão até a F10) ele só olha a tabela.
Rails.application.config.after_initialize do
  SolidQueue.on_worker_start { Tuya::Listener.start } if defined?(SolidQueue) && ENV["TUYA_LISTENER"] != "off"
  # Ouvinte MQTT (F8): só com MQTT_URL (servidor local com o Mosquitto).
  SolidQueue.on_worker_start { Mqtt::Listener.start } if defined?(SolidQueue)
  # Leitura periódica dos aparelhos Xiaomi (F8); MIIO_POLLER=off desliga.
  SolidQueue.on_worker_start { Miio::Poller.start } if defined?(SolidQueue) && ENV["MIIO_POLLER"] != "off"
end
