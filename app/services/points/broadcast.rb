module Points
  # Aviso às telas de que o ponto mudou (Performance 3 e 4): o refresh da
  # página do ponto e o `point_changed` (só o id) no stream do local, que faz
  # cada painel recarregar os widgets que dependem dele.
  #
  # Medição que muda toda hora (potência, tensão) avisa no máximo uma vez a
  # cada `window` s por ponto: a primeira mudança sai na hora e as seguintes
  # dentro da janela viram UM aviso no fim dela (a tela relê o ponto e pega
  # o último valor; nada se perde). Liga/desliga, porta, movimento e mudança
  # de qualidade avisam sempre na hora. A janela é por processo (quem lê o
  # aparelho é o worker); `address.notify_s` no ponto troca a janela (0 = na hora).
  module Broadcast
    # Capacidades agrupadas (dado: o que é medição contínua).
    THROTTLED = %w[measure counter].freeze
    WINDOW = 1.5

    @last = Concurrent::Map.new
    @pending = Concurrent::Map.new

    module_function

    # Janela do ponto em segundos (0 = sem agrupar).
    def window(point)
      return 0.0 unless enabled?

      custom = point.address.to_h["notify_s"]
      return custom.to_f.clamp(0.0, 10.0) if custom.present?

      point.capability.in?(THROTTLED) ? WINDOW : 0.0
    end

    # `grouped`: mudança só de valor (a de qualidade e o comando sempre saem na hora).
    def changed(point, grouped: false)
      win = grouped ? window(point) : 0.0
      streams = [ point.to_gid_param, point.site.to_gid_param, point.id ]
      return send!(*streams) if win <= 0

      now = clock
      last = @last[point.id]
      if last.nil? || now - last >= win
        @last[point.id] = now
        send!(*streams)
      elsif @pending.put_if_absent(point.id, true).nil?
        Concurrent::ScheduledTask.execute(win - (now - last)) { trailing(*streams) }
      end
    end

    # O aviso guardado do fim da janela (thread do temporizador: pega uma conexão e devolve).
    def trailing(point_gid, site_gid, id)
      @pending.delete(id)
      @last[id] = clock
      Rails.application.executor.wrap { send!(point_gid, site_gid, id) }
    rescue StandardError => e
      Rails.error.report(e, handled: true)
    end

    def send!(point_gid, site_gid, id)
      Turbo::StreamsChannel.broadcast_refresh_to(point_gid)
      Turbo::StreamsChannel.broadcast_action_to(site_gid, :points, action: :point_changed, target: id)
    end

    def clock = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    # Nos testes não agrupa (cada `report!` avisa), a não ser que o spec ligue.
    def enabled? = @enabled.nil? ? !Rails.env.test? : @enabled
    def enabled=(on)
      @enabled = on
    end

    def reset!
      @last.clear
      @pending.clear
    end
  end
end
