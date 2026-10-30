module Tuya
  # Ouvinte persistente dos aparelhos tuya_local com `listen` ligado: uma
  # thread por aparelho mantém a conexão, manda heartbeat e passa cada
  # empurrão de status (botão físico, app da Tuya) para `Point#report!`.
  # Caiu: pontos ficam `unavailable` e reconecta com espera crescente.
  #
  # Roda dentro do processo worker do Solid Queue (on_worker_start), o mesmo
  # que executa os comandos: o driver usa a conexão aberta daqui.
  # ponytail: um processo worker só (JOB_CONCURRENCY=1); com mais, cada um
  # abriria a sua conexão — aí o ouvinte vira um processo próprio.
  class Listener
    SCAN_EVERY = 30
    HEARTBEAT_EVERY = 10
    SILENCE_LIMIT = 30
    MAX_BACKOFF = 60

    @connections = Concurrent::Map.new
    @threads = Concurrent::Map.new

    class << self
      def connection(device_id)
        conn = @connections[device_id]
        conn if conn&.open?
      end

      def start
        return if @supervisor&.alive?

        @supervisor = Thread.new do
          loop do
            scan
            sleep SCAN_EVERY
          end
        end
      end

      # Liga as threads dos aparelhos com `listen` e encerra as que saíram.
      def scan
        wanted = Rails.application.executor.wrap do
          ActsAsTenant.without_tenant { Device.where(driver: "tuya_local", listen: true, disabled: false).pluck(:id) }
        end
        (@threads.keys - wanted).each { |id| @threads.delete(id)&.kill && @connections.delete(id)&.close }
        wanted.each { |id| @threads[id] = Thread.new { listen(id) } unless @threads[id]&.alive? }
      rescue StandardError => e
        Rails.error.report(e, handled: true)
      end

      def listen(device_id)
        failures = 0
        loop do
          failures = run_once(device_id) ? 0 : failures + 1
          sleep [ 2**failures, MAX_BACKOFF ].min
        end
      end

      # Uma sessão com o aparelho: true se chegou a conectar.
      def run_once(device_id)
        device = with_device(device_id) { |d| d }
        return true unless device

        conn = Drivers::TuyaLocal.connection_for(device).connect
        @connections[device_id] = conn
        with_device(device_id) { |d| Drivers::TuyaLocal.report(d, conn.status) }
        loop_messages(device_id, conn)
      rescue Tuya::Connection::Error, Tuya::Protocol::Error, Drivers::TuyaLocal::Error => e
        Rails.logger.warn("[tuya] #{device_id}: #{e.message}")
        with_device(device_id) { |d| Drivers::TuyaLocal.unavailable!(d) }
        !conn.nil?
      ensure
        @connections.delete(device_id)
        conn&.close
      end

      private

      def loop_messages(device_id, conn)
        last_beat = last_heard = monotonic
        loop do
          if (msg = conn.read(1))
            last_heard = monotonic
            dps = msg.dps
            with_device(device_id) { |d| Drivers::TuyaLocal.report(d, dps, push: true) } if dps.is_a?(Hash) && dps.any?
          end
          raise Tuya::Connection::Error, "aparelho calado há #{SILENCE_LIMIT}s" if monotonic - last_heard > SILENCE_LIMIT
          next unless monotonic - last_beat > HEARTBEAT_EVERY

          conn.heartbeat
          last_beat = monotonic
        end
      end

      def with_device(device_id)
        Rails.application.executor.wrap do
          device = ActsAsTenant.without_tenant { Device.find_by(id: device_id) }
          device && ActsAsTenant.with_tenant(device.tenant) { yield device }
        end
      end

      def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
