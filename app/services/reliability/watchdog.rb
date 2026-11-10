module Reliability
  # Vigia da fila fora do worker (docs/confiabilidade.md). Roda numa thread do
  # supervisor do Solid Queue (`SolidQueue.on_start`): se o worker travar ou
  # morrer, o HealthCheckJob não roda (é tarefa da própria fila), então quem
  # avisa é este. A cada INTERVAL olha a verificação "Fila de tarefas"
  # (`Health::Checks::Queues`: trabalhador sem sinal, tarefa pronta esperando
  # mais de 5 min, pico de falhas) e manda o aviso dos itens com erro com o
  # push entregue na hora (o SendPushJob dependeria da fila parada). Mesmo
  # `dedup_key` do HealthCheckJob: um aviso por problema por dia.
  module Watchdog
    INTERVAL = 60

    module_function

    def start
      return if @thread&.alive?

      @thread = Thread.new do
        Thread.current.name = "reliability-watchdog"
        loop do
          sleep INTERVAL
          check!
        end
      end
    end

    def check!(now: Time.current)
      Rails.application.executor.wrap do
        Tenant.find_each { |t| Health.alert!(t, now: now, only: Health::Checks::Queues.key, push_now: true) }
      end
    rescue StandardError => e
      Rails.error.report(e, handled: true)
    end
  end
end
