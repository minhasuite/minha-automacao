# Ouvinte Tuya (Tuya::Listener) no processo worker do Solid Queue. Sem
# aparelho com `listen` ligado (VPS, padrão até a F10) ele só olha a tabela.
Rails.application.config.after_initialize do
  SolidQueue.on_worker_start { Tuya::Listener.start } if defined?(SolidQueue) && ENV["TUYA_LISTENER"] != "off"
  # Tempo real da nuvem Tuya (Lote 6): só conecta com aparelho da conta adotado.
  SolidQueue.on_worker_start { Tuya::CloudListener.start } if defined?(SolidQueue) && ENV["TUYA_CLOUD_LISTENER"] != "off"
  # Ouvinte MQTT (F8): só com MQTT_URL (servidor local com o Mosquitto).
  SolidQueue.on_worker_start { Mqtt::Listener.start } if defined?(SolidQueue)
  # Movimento das câmeras ONVIF (Lote 3); sem câmera com ponto de movimento, só olha a tabela.
  SolidQueue.on_worker_start { Onvif::Listener.start } if defined?(SolidQueue) && ENV["ONVIF_LISTENER"] != "off"
  # Leitura periódica (F8: Tuya, Xiaomi, lista de Echo); POLLING=off desliga.
  SolidQueue.on_worker_start { Polling.start } if defined?(SolidQueue) && ENV["POLLING"] != "off"
  # Helpers sem "restaurar depois de reiniciar" voltam ao valor inicial (F8e).
  SolidQueue.on_worker_start { HelperTypes.boot! } if defined?(SolidQueue)
  # Gatilho "Sistema iniciou" (Lote 5, G7): uma vez por início do supervisor.
  SolidQueue.on_start { SystemStartedJob.perform_later } if defined?(SolidQueue)
end
