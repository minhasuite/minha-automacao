module Mqtt
  # Conexão persistente com o broker (MQTT_URL) no processo worker: assina os
  # tópicos de estado dos pontos `mqtt` (e o `bridge/devices` do zigbee2mqtt,
  # para a descoberta) e passa cada mensagem para `Point#report!`. Caiu: os
  # pontos ficam `unavailable` e reconecta com espera crescente (até 60 s);
  # as mensagens retidas devolvem o valor na volta. Sem MQTT_URL (VPS) não
  # liga, e o comando falha com "MQTT não configurado".
  class Listener
    # Descobridores (Pacote 1): cada um diz os tópicos que assina (`topics`,
    # curinga vale), se trata um tópico (`handles?`) e trata (`handle`).
    # Descoberta nova = módulo em Mqtt + nome aqui.
    # integ: "Frigate" = ::Frigate (eventos de detecção e contagem por câmera).
    # ondaC1 (C4): HaDiscovery = o formato `homeassistant/` de todo o resto.
    # Descobridor com `connected(client)` publica ao conectar (birth message).
    # apps: DoubleTake (rosto reconhecido) e Espresense (cômodo por Bluetooth).
    DISCOVERY = %w[Z2m Tasmota Frigate DoubleTake Espresense HaDiscovery].freeze
    SCAN_EVERY = 30
    MAX_BACKOFF = 60

    class << self
      def start
        return if Drivers::Mqtt.url.nil? || @thread&.alive?

        @thread = Thread.new do
          failures = 0
          loop do
            failures = session ? 0 : failures + 1
            sleep [ 2**failures, MAX_BACKOFF ].min
          end
        end
      end

      # Usa a conexão do ouvinte; sem ela (outro processo, ouvinte parado), uma curta.
      def publish(topic, payload, retain: false)
        url = Drivers::Mqtt.url or raise Drivers::Mqtt::Error, "MQTT não configurado neste servidor."
        args = [ topic, payload, (true if retain) ].compact
        if @client&.connected?
          @client.publish(*args)
        else
          MQTT::Client.connect(url) { |c| c.publish(*args) }
        end
      rescue MQTT::Exception, SystemCallError, SocketError, Timeout::Error => e
        raise Drivers::Mqtt::Error, "Sem conexão com o broker MQTT: #{e.message}"
      end

      # Uma sessão com o broker: true se chegou a conectar.
      def session
        connected = false
        MQTT::Client.connect(Drivers::Mqtt.url, keep_alive: 15) do |client|
          @client = client
          connected = true
          discoverers.each { |d| wrap { d.connected(client) } if d.respond_to?(:connected) }
          subscribed = Set.new
          next_scan = 0
          loop do
            if monotonic >= next_scan
              (topics - subscribed.to_a).each { |t| client.subscribe(t => 0) && subscribed << t }
              next_scan = monotonic + SCAN_EVERY
            end
            next sleep(0.2) if client.queue_empty?

            topic, payload = client.get
            handle(topic, payload)
          end
        end
      rescue MQTT::Exception, SystemCallError, SocketError, Timeout::Error, IOError => e
        Rails.logger.warn("[mqtt] #{e.class}: #{e.message}")
        unavailable!
        connected
      ensure
        @client = nil
      end

      def discoverers = DISCOVERY.map { |name| Mqtt.const_get(name) }

      def topics
        wrap do
          list = Point.joins(:device).where(devices: { driver: "mqtt", disabled: false }).distinct.pluck(Arel.sql("points.address->>'topic'")).compact_blank
          (list + discoverers.flat_map(&:topics) + Automations::TriggerTypes::MqttTrigger.topics).uniq
        end
      end

      def handle(topic, payload)
        wrap { Automations::TriggerTypes::MqttTrigger.receive(topic, payload) } # ondaA1 (A5): gatilho MQTT
        wrap do
          discovery = discoverers.find { |x| x.handles?(topic) }
          next discovery.handle(topic, payload) if discovery

          Point.joins(:device).where(devices: { driver: "mqtt", disabled: false }).where("points.address->>'topic' = ?", topic).includes(:device).find_each do |point|
            value = Drivers::Mqtt.value_for(point, payload)
            next if value.nil?

            ActsAsTenant.with_tenant(point.tenant) do
              point.device.update_columns(status: "online", last_seen_at: Time.current)
              point.report!(value)
            end
          end
        end
      rescue StandardError => e
        Rails.error.report(e, handled: true)
      end

      def unavailable!
        wrap do
          Point.joins(:device).where(devices: { driver: "mqtt" }).where.not(quality: "unavailable").find_each do |p|
            ActsAsTenant.with_tenant(p.tenant) { p.report!(p.value, quality: "unavailable") }
          end
        end
      rescue StandardError => e
        Rails.error.report(e, handled: true)
      end

      private

      def wrap(&) = Rails.application.executor.wrap { ActsAsTenant.without_tenant(&) }
      def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
