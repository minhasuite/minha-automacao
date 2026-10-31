module Matter
  # Tempo real do Matter (Pacote 1): uma conexão por integração com aparelho
  # adotado, no processo worker (MATTER_LISTENER=off desliga). `start_listening`
  # devolve os nós (estado de todos) e depois chegam os eventos:
  # `attribute_updated` [nó, "ep/cluster/atributo", valor] → ponto;
  # `node_updated`/`node_added` → refaz o aparelho; `node_removed` →
  # indisponível. Caiu = aparelhos indisponíveis e nova tentativa com espera
  # crescente até 60 s.
  class Listener
    SCAN_EVERY = 30
    MAX_BACKOFF = 60

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
        wanted = wrap { Device.where(driver: "matter", removed_at: nil, disabled: false).where.not(integration_id: nil).distinct.pluck(:integration_id) }
        (@threads.keys - wanted).each { |id| @threads.delete(id)&.kill }
        wanted.each { |id| @threads[id] = Thread.new { listen(id) } unless @threads[id]&.alive? }
      rescue StandardError => e
        Rails.error.report(e, handled: true)
      end

      def listen(id)
        failures = 0
        loop do
          failures = session(id) ? 0 : failures + 1
          sleep [ 2**failures, MAX_BACKOFF ].min
        end
      end

      # Uma sessão: true se chegou a conectar.
      def session(id, client: nil)
        url = wrap { Integration.find_by(id: id)&.settings&.dig("url") }
        client ||= Client.new(url).connect
        nodes = client.start_listening
        wrap { Array(nodes).each { |n| handle(id, { "event" => "node_updated", "data" => n }) } }
        until client.closed?
          ev = client.next_event(SCAN_EVERY) or next
          wrap { handle(id, ev) }
        end
        true
      rescue Client::Error => e
        Rails.logger.warn("[matter] #{e.message}")
        wrap { devices(id).each { |d| ActsAsTenant.with_tenant(d.tenant) { Drivers::Matter.unavailable!(d) } } }
        !client.nil?
      ensure
        client&.close
      end

      def handle(id, ev)
        case ev["event"]
        when "attribute_updated"
          node, path, raw = ev["data"]
          device = devices(id).find { |d| d.external_id == node.to_s } or return
          ActsAsTenant.with_tenant(device.tenant) do
            device.points.select { |p| Map.path(p) == path }.each { |p| (v = Map.value(p, raw)).nil? || p.report!(v) }
            device.update_columns(status: "online", last_seen_at: Time.current)
          end
        when "node_updated", "node_added"
          device = devices(id).find { |d| d.external_id == ev.dig("data", "node_id").to_s } or return
          ActsAsTenant.with_tenant(device.tenant) { Map.apply(device, ev["data"]) }
        when "node_removed"
          device = devices(id).find { |d| d.external_id == ev["data"].to_s } or return
          ActsAsTenant.with_tenant(device.tenant) { Drivers::Matter.unavailable!(device) }
        end
      rescue StandardError => e
        Rails.error.report(e, handled: true)
      end

      def devices(id) = Device.where(driver: "matter", integration_id: id, removed_at: nil, disabled: false).includes(:points).to_a

      private

      def wrap(&) = Rails.application.executor.wrap { ActsAsTenant.without_tenant(&) }
    end
  end
end
