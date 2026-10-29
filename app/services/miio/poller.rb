module Miio
  # Lê os aparelhos `xiaomi_miot` a cada `Drivers::XiaomiMiot::POLL_EVERY`
  # segundos (uma chamada get_properties por aparelho, pela rede local: não
  # passa pela nuvem nem atrapalha o HA). Falhou = pontos `unavailable`.
  # Roda no processo worker (on_worker_start); sem aparelho, só dorme.
  # ponytail: uma thread para todos, em sequência; com muitos aparelhos, uma por aparelho.
  module Poller
    class << self
      def start
        return if @thread&.alive?

        @thread = Thread.new do
          loop do
            tick
            sleep Drivers::XiaomiMiot::POLL_EVERY
          end
        end
      end

      def tick
        ids = wrap { Device.where(driver: "xiaomi_miot", disabled: false).pluck(:id) }
        ids.each { |id| poll(id) }
      rescue StandardError => e
        Rails.error.report(e, handled: true)
      end

      def poll(id)
        wrap do
          device = Device.find_by(id: id) or next
          ActsAsTenant.with_tenant(device.tenant) do
            Drivers::XiaomiMiot.poll(device)
          rescue Miio::Client::Error, Miio::Protocol::Error, Drivers::XiaomiMiot::Error => e
            Rails.logger.warn("[miio] #{device.name}: #{e.message}")
            Drivers::XiaomiMiot.unavailable!(device)
          end
        end
      end

      private

      def wrap(&) = Rails.application.executor.wrap { ActsAsTenant.without_tenant(&) }
    end
  end
end
