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
  # Tempo real do ESPHome e do Matter (Pacote 1); sem aparelho adotado, só olham a tabela.
  SolidQueue.on_worker_start { Esphome::Listener.start } if defined?(SolidQueue) && ENV["ESPHOME_LISTENER"] != "off"
  SolidQueue.on_worker_start { Matter::Listener.start } if defined?(SolidQueue) && ENV["MATTER_LISTENER"] != "off"
  # ondaC1 (C1): Z-Wave JS em tempo real e a inclusão pedida na tela.
  SolidQueue.on_worker_start { ZwaveJs::Listener.start } if defined?(SolidQueue) && ENV["ZWAVE_LISTENER"] != "off"
  # ondaB1 (B6): satélites de voz (Wyoming, ESPHome).
  SolidQueue.on_worker_start { Assist::Satellites::Listener.start } if defined?(SolidQueue) && ENV["ASSIST_SATELLITES"] != "off"
  # ondaC2 (C10): gravação contínua das câmeras (só com GO2RTC_URL).
  SolidQueue.on_worker_start { Recordings::Recorder.start } if defined?(SolidQueue) && ENV["RECORDINGS"] != "off"
  # Leitura periódica (F8: Tuya, Xiaomi, lista de Echo); POLLING=off desliga.
  SolidQueue.on_worker_start { Polling.start } if defined?(SolidQueue) && ENV["POLLING"] != "off"
  # Helpers sem "restaurar depois de reiniciar" voltam ao valor inicial (F8e).
  SolidQueue.on_worker_start { HelperTypes.boot! } if defined?(SolidQueue)
  # Gatilho "Sistema iniciou" (Lote 5, G7): uma vez por início do supervisor.
  SolidQueue.on_start { SystemStartedJob.perform_later } if defined?(SolidQueue)
  # ondaA1 (A5): gatilho "Sistema vai desligar" (na hora, antes de o processo sair).
  SolidQueue.on_stop { Automations::Triggers.system_stopping! } if defined?(SolidQueue)
  # Respostas de botão do Telegram sem webhook (Pacote 4); TELEGRAM_LISTENER=off desliga.
  SolidQueue.on_worker_start { Integrations::TelegramPlugin.listen } if defined?(SolidQueue) && ENV["TELEGRAM_LISTENER"] != "off"
end
