# Confiabilidade (docs/confiabilidade.md), nos processos do Solid Queue:
# - início do worker: fecha as execuções de automação que o processo anterior
#   deixou "rodando" (depois de AutomationRun::STALE, para não pegar uma que a
#   web acabou de começar);
# - supervisor: vigia a fila de fora do worker (Reliability::Watchdog) e avisa
#   quando ela para; o aviso sai com o push na hora, sem depender do worker.
#   RELIABILITY_WATCHDOG=off desliga.
Rails.application.config.after_initialize do
  next unless defined?(SolidQueue)

  SolidQueue.on_worker_start do
    AutomationSweepJob.set(wait: AutomationRun::STALE).perform_later(Time.current.iso8601(3))
  rescue StandardError => e
    Rails.error.report(e, handled: true)
  end
  SolidQueue.on_start { Reliability::Watchdog.start } if ENV["RELIABILITY_WATCHDOG"] != "off"
end
