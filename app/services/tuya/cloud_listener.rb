module Tuya
  # Tempo real da nuvem Tuya, como o tuya-device-sharing-sdk do HA: pede a
  # credencial do MQTT da conta (`Cloud#mqtt_config`), conecta por TLS e assina
  # o tópico de cada aparelho da integração que está no local. Mensagem
  # `protocol` 4 = status ({dpId|code, value}) → pontos (conta `push_only`,
  # o clique do botão); 20 = online/offline. Ao conectar lê o estado de todos
  # (2 pedidos). A credencial vence (`expireTime`): reconecta antes. Caiu =
  # aparelhos `tuya_cloud` indisponíveis e nova tentativa com espera crescente.
  # Uma thread por integração no processo worker (TUYA_CLOUD_LISTENER=off
  # desliga); sem aparelho adotado, nada conecta.
  class CloudListener
    SCAN_EVERY = 30
    MAX_BACKOFF = 60
    MAX_SESSION = 2 * 3600
    REPORT = 4
    OTHER = 20

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
        wanted = wrap { integration_ids }
        (@threads.keys - wanted).each { |id| @threads.delete(id)&.kill }
        wanted.each { |id| @threads[id] = Thread.new { listen(id) } unless @threads[id]&.alive? }
      rescue StandardError => e
        Rails.error.report(e, handled: true)
      end

      def integration_ids
        Integration.where(driver: Integrations::TuyaPlugin.driver, status: %w[ok syncing])
                   .where(id: Device.where(driver: Cloud::DRIVERS, removed_at: nil, disabled: false).select(:integration_id)).pluck(:id)
      end

      def listen(id)
        failures = 0
        loop do
          failures = session(id) ? 0 : failures + 1
          sleep [ 2**failures, MAX_BACKOFF ].min
        end
      end

      # Uma sessão: true se conectou (ou não há o que ouvir).
      def session(id)
        config = with_integration(id) { |i| Cloud.new(i).mqtt_config } or return true
        client = connect(config)
        with_integration(id) { |i| refresh(i) }
        pump(id, client, config)
        true
      rescue MQTT::Exception, SystemCallError, SocketError, Timeout::Error, IOError, OpenSSL::SSL::SSLError, Integrations::Error => e
        Rails.logger.warn("[tuya-cloud] #{e.class}: #{e.message}")
        with_integration(id) { |i| Integrations::TuyaPlugin.devices(i).where(driver: "tuya_cloud").find_each { |d| Drivers::TuyaLocal.unavailable!(d) } }
        !client.nil?
      ensure
        client&.disconnect
      end

      def connect(config)
        uri = URI(config["url"].to_s)
        MQTT::Client.connect(host: uri.host, port: uri.port || 8883, ssl: %w[ssl mqtts].include?(uri.scheme),
                             client_id: config["clientId"], username: config["username"], password: config["password"], keep_alive: 60)
      end

      def topic(config, device_id) = config.dig("topic", "devId", "sub").to_s.sub("{devId}", device_id.to_s)

      # Lê as mensagens até a credencial vencer; assina aparelho novo a cada SCAN_EVERY.
      def pump(id, client, config)
        until_at = monotonic + config["expireTime"].to_i.clamp(120, MAX_SESSION) - 60
        subscribed = Set.new
        next_scan = 0
        while monotonic < until_at
          if monotonic >= next_scan
            topics = with_integration(id) { |i| Integrations::TuyaPlugin.devices(i).pluck(:external_id).compact.map { |d| topic(config, d) } }.to_a
            (topics - subscribed.to_a).each { |t| client.subscribe(t => 1) && subscribed << t }
            next_scan = monotonic + SCAN_EVERY
          end
          next sleep(0.2) if client.queue_empty?

          _topic, payload = client.get
          with_integration(id) { |i| handle(i, payload) }
        end
      end

      def refresh(integration)
        states = Cloud.new(integration).states
        Integrations::TuyaPlugin.devices(integration).find_each do |d|
          Integrations::TuyaPlugin.apply(d, states[d.external_id]) if states[d.external_id]
        end
      end

      # Mensagem do MQTT (JSON do SDK) → pontos do aparelho.
      def handle(integration, payload)
        msg = JSON.parse(payload.to_s)
        data = msg["data"].is_a?(Hash) ? msg["data"] : {}
        if msg["protocol"] == REPORT
          device = find(integration, data["devId"]) or return
          state = Array(data["status"]).each_with_object({}) { |s, h| h[(s["dpId"] || s["code"]).to_s] = s["value"] if s.is_a?(Hash) && s.key?("value") }
          Drivers::TuyaCloud.report(device, state, push: true)
        elsif msg["protocol"] == OTHER
          device = find(integration, data.dig("bizData", "devId")) or return
          data["bizCode"] == "offline" ? Drivers::TuyaLocal.unavailable!(device) : (device.update_columns(status: "online") if data["bizCode"] == "online")
        end
      rescue JSON::ParserError
        nil
      end

      private

      def find(integration, device_id) = device_id.present? && Integrations::TuyaPlugin.devices(integration).find_by(external_id: device_id.to_s)

      def with_integration(id)
        wrap do
          integration = Integration.find_by(id: id)
          integration && ActsAsTenant.with_tenant(integration.tenant) { yield integration }
        end
      end

      def wrap(&) = Rails.application.executor.wrap { ActsAsTenant.without_tenant(&) }

      def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
