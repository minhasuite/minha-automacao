module Esphome
  # Tempo real do ESPHome no processo worker, no padrão do Onvif::Listener:
  # uma thread por aparelho `esphome` ligado, conexão aberta com os estados
  # assinados; cada mensagem de estado vira `Point#report!`. Caiu: pontos
  # `unavailable` e nova tentativa com espera crescente (até 60 s). O
  # aparelho aceita várias conexões, então o comando e a leitura periódica
  # seguem em conexões curtas. ESPHOME_LISTENER=off desliga.
  class Listener
    SCAN_EVERY = 60
    MAX_BACKOFF = 60
    IDLE = 30 # sem nada nesse tempo, manda um ping (o aparelho derruba conexão muda)

    @threads = Concurrent::Map.new

    class << self
      def start
        return if @supervisor&.alive?

        @supervisor = Thread.new do
          loop do
            scan
            sleep SCAN_EVERY
          end
        end
      end

      def scan
        wanted = Rails.application.executor.wrap { ActsAsTenant.without_tenant { Device.where(driver: "esphome", disabled: false, removed_at: nil).pluck(:id) } }
        (@threads.keys - wanted).each { |id| @threads.delete(id)&.kill }
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

      # Uma conexão: true se chegou a conectar. `rounds` limita o laço (specs).
      def run_once(device_id, rounds: nil)
        client = nil
        with_device(device_id) { |d| client = ::Esphome.client_for(d) }
        return true unless client

        client.connect
        client.subscribe_states
        n = 0
        until rounds && (n += 1) > rounds
          type, f = client.read(IDLE)
          next client.send_message(Client::PING_REQ) unless type

          key, kind, fields = Client.state_of(type, f)
          with_device(device_id) { |d| ::Esphome.report(d, { key => [ kind, fields ] }) } if key
        end
        true
      rescue Error, SystemCallError, IOError => e
        Rails.logger.warn("[esphome] #{device_id}: #{e.message}")
        with_device(device_id) { |d| Drivers::Esphome.unavailable!(d) }
        false
      ensure
        client&.close
      end

      private

      def with_device(device_id)
        Rails.application.executor.wrap do
          device = ActsAsTenant.without_tenant { Device.find_by(id: device_id) }
          device && ActsAsTenant.with_tenant(device.tenant) { yield device }
        end
      end
    end
  end
end
