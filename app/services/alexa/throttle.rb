module Alexa
  # Ritmo por conta da Alexa (docs/confiabilidade.md): a API não oficial
  # devolve 429 com dois pedidos no mesmo segundo. Cada pedido de uma conta
  # reserva a sua vez (GAP entre um e outro) e espera fora da trava; um 429
  # empurra a próxima vez da conta para depois do Retry-After. Na memória do
  # processo: os comandos saem todos pelo worker (um processo só).
  module Throttle
    GAP = 1.5
    MAX_WAIT = 20.0
    @lock = Mutex.new
    @next = {}

    mattr_accessor :gap, default: GAP

    module_function

    # Espera a vez da conta `key` (nil = sem ritmo) e devolve quanto esperou.
    def wait(key)
      return 0 if key.nil?

      delay = @lock.synchronize do
        now = clock
        at = [ @next[key].to_f, now ].max
        @next[key] = at + gap
        at - now
      end
      delay = delay.clamp(0, MAX_WAIT)
      sleep(delay) if delay.positive?
      delay
    end

    # Recusa (429): ninguém da conta pede antes de `seconds`.
    def hold(key, seconds)
      return if key.nil?

      @lock.synchronize { @next[key] = [ @next[key].to_f, clock + seconds.to_f ].max }
    end

    def reset! = @lock.synchronize { @next.clear }
    def clock = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end
end
