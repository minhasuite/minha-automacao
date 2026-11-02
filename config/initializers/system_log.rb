# ondaA2 A12: avisos e erros do servidor em Configurações → Logs (SystemLog).
# Fora do teste; SYSTEM_LOG=0 desliga.
Rails.application.config.after_initialize do
  Rails.logger.broadcast_to(SystemLog::Sink.new) unless Rails.env.test? || ENV["SYSTEM_LOG"] == "0"
end
