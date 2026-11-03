module ZwaveJs
  # Tempo real do Z-Wave JS (ondaC1, C1): uma conexão por integração com nó
  # adotado ou com inclusão/exclusão pedida na tela, no processo worker
  # (ZWAVE_LISTENER=off desliga). Depois do `start_listening` chegam os
  # eventos: `value updated`/`value notification` → ponto; `dead`/`alive` →
  # aparelho; e os do controlador na inclusão (`grant security classes`,
  # `validate dsk and enter pin`, `node added`, `node removed`…), que vão
  # para o ZwaveJs::Inclusion (a tela mostra e responde). Caiu = nova
  # tentativa com espera crescente até 60 s.
  class Listener
    SCAN_EVERY = 5
    TICK = 1
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
        wanted = wrap { Integration.where(driver: "zwave_js").pluck(:id).select { |id| Inclusion.active?(id) || devices(id).any? } }
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

      # Uma sessão: true se chegou a conectar. `ticks` limita as voltas (spec).
      def session(id, client: nil, ticks: nil)
        url = wrap { Integration.find_by(id: id)&.settings&.dig("url") }
        client ||= Client.new(url).connect
        state = client.state
        wrap { nodes_applied(id, state) }
        n = 0
        until client.closed? || (ticks && (n += 1) > ticks)
          wrap { pump(id, client) }
          ev = client.next_event(TICK) or next
          wrap { handle(id, ev["event"].to_h) }
        end
        true
      rescue Error => e
        Rails.logger.warn("[zwave_js] #{e.message}")
        wrap { devices(id).each { |d| ActsAsTenant.with_tenant(d.tenant) { Drivers.offline!(d) } } }
        !client.nil?
      ensure
        client&.close
      end

      def nodes_applied(id, state)
        by_node = Array(state["nodes"]).index_by { |n| n["nodeId"].to_s }
        devices(id).each { |d| (n = by_node[d.address["node"].to_s]) && ActsAsTenant.with_tenant(d.tenant) { ZwaveJs.apply(d, n) } }
      end

      # O que a tela pediu → comando no servidor.
      def pump(id, client)
        s = Inclusion.get(id)
        exclude = s["mode"] == "exclude"
        case s["state"]
        when "requested"
          exclude ? client.begin_exclusion : client.begin_inclusion(STRATEGIES.fetch(s["strategy"].to_s, 0))
          Inclusion.update(id, state: "running")
        when "granted"
          client.grant(Array(s["grant"]).map(&:to_i))
          Inclusion.update(id, state: "running")
        when "pin"
          client.validate_dsk(s["pin"].to_s)
          Inclusion.update(id, state: "running", pin: nil)
        when "stop"
          exclude ? client.stop_exclusion : client.stop_inclusion
          Inclusion.update(id, state: "stopped")
        end
      rescue Error => e
        Inclusion.update(id, state: "failed", message: e.message)
      end

      def handle(id, ev)
        node = ev["nodeId"] || ev.dig("node", "nodeId")
        case ev["event"]
        when "value updated", "value notification"
          args = ev["args"].to_h
          raw = args.key?("newValue") ? args["newValue"] : args["value"]
          device = device_for(id, node) or return
          ActsAsTenant.with_tenant(device.tenant) do
            device.points.reject(&:disabled).select { |p| ZwaveJs.same?(p.address, args) }.each { |p| (v = ZwaveJs.value(p, raw)).nil? || p.report!(v) }
            device.update_columns(status: "online", last_seen_at: Time.current)
          end
        when "dead" then (d = device_for(id, node)) && ActsAsTenant.with_tenant(d.tenant) { Drivers.offline!(d) }
        when "alive", "wake up" then device_for(id, node)&.update_columns(status: "online", last_seen_at: Time.current)
        when "grant security classes" then Inclusion.update(id, state: "grant", requested: Array(ev.dig("requested", "securityClasses")))
        when "validate dsk and enter pin" then Inclusion.update(id, state: "dsk", dsk: ev["dsk"])
        when "node added" then Inclusion.update(id, state: "added", node: node, low_security: ev.dig("result", "lowSecurity") == true)
        when "interview completed" then finished(id, "done") if Inclusion.get(id)["node"].to_s == node.to_s
        when "node removed" then finished(id, "removed", node: node)
        when "inclusion stopped", "exclusion stopped" then Inclusion.update(id, state: "stopped") if %w[running grant dsk].include?(Inclusion.get(id)["state"])
        when "inclusion failed", "exclusion failed" then Inclusion.update(id, state: "failed")
        end
      rescue StandardError => e
        Rails.error.report(e, handled: true)
      end

      # Nó novo entrevistado ou nó tirado: varre de novo (o novo aparece em "Encontrados").
      def finished(id, state, **extra)
        Inclusion.update(id, state: state, **extra)
        (i = Integration.find_by(id: id)) && Integrations.start_sync!(i)
      end

      def devices(id) = Device.where(driver: "zwave_js", integration_id: id, removed_at: nil, disabled: false).includes(:points).to_a
      def device_for(id, node) = node && devices(id).find { |d| d.address["node"].to_s == node.to_s }

      private

      def wrap(&) = Rails.application.executor.wrap { ActsAsTenant.without_tenant(&) }
    end
  end
end
