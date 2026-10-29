# Ouvinte Tuya (Tuya::Listener) no processo worker do Solid Queue. Sem
# aparelho com `listen` ligado (VPS, padrão até a F10) ele só olha a tabela.
Rails.application.config.after_initialize do
  SolidQueue.on_worker_start { Tuya::Listener.start } if defined?(SolidQueue) && ENV["TUYA_LISTENER"] != "off"
end
