# Tarefa lenta (Performance 7: varredura, backup, rollup, migração do HA…):
# fila `slow`, prioridade baixa e no máximo JOB_SLOW_THREADS (2) rodando ao
# mesmo tempo no worker, somadas todas as classes lentas. Assim sobra thread
# para os comandos (`commands`, prioridade -10) e o resto, sem um segundo
# processo de worker (os ouvintes Tuya/MQTT exigem um só; ver config/queue.yml).
module SlowJob
  extend ActiveSupport::Concern

  LIMIT = ENV.fetch("JOB_SLOW_THREADS", 2).to_i.clamp(1, 16)

  included do
    queue_as :slow
    queue_with_priority 10
    # Semáforo do Solid Queue: a terceira espera (bloqueada) até uma acabar; se o
    # worker cair no meio, a vaga volta sozinha depois de `duration`.
    limits_concurrency to: LIMIT, key: "lentas", group: "lentas", duration: 3.hours if respond_to?(:limits_concurrency)
  end
end
