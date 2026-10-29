# Streams do go2rtc iguais às câmeras cadastradas (a cada minuto; recoloca
# tudo depois que o go2rtc reinicia). Sem GO2RTC_URL (VPS) não faz nada.
class Go2rtcSyncJob < ApplicationJob
  queue_as :default

  def perform = Drivers::Go2rtc.sync!
end
