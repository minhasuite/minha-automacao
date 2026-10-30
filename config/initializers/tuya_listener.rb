# Ouvinte Tuya (Tuya::Listener) no processo worker do Solid Queue. Sem
# aparelho com `listen` ligado (VPS, padrão até a F10) ele só olha a tabela.
Rails.application.config.after_initialize do
  SolidQueue.on_worker_start { Tuya::Listener.start } if defined?(SolidQueue) && ENV["TUYA_LISTENER"] != "off"
  # Ouvinte MQTT (F8): só com MQTT_URL (servidor local com o Mosquitto).
  SolidQueue.on_worker_start { Mqtt::Listener.start } if defined?(SolidQueue)
  # Leitura periódica (F8: Tuya, Xiaomi, lista de Echo); POLLING=off desliga.
  SolidQueue.on_worker_start { Polling.start } if defined?(SolidQueue) && ENV["POLLING"] != "off"
end
