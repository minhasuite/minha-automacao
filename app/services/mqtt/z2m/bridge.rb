module Mqtt
  module Z2m
    # A ponte do zigbee2mqtt como adaptador de pareamento (`Pairing::Adapter`,
    # docs/integracoes.md, "Zigbee"). Pedidos saem por
    # `<base>/bridge/request/...` (pela conexão do ouvinte ou uma curta) e as
    # respostas e eventos chegam pelo ouvinte (`receive`), que grava o estado
    # da ponte (`PairingBridge`) e os aparelhos que entraram (`PairingJoin`).
    class Bridge < Pairing::Adapter
      # Mesmo sinal (linkquality) só regrava depois disso; mudança grande grava na hora.
      LQI_EVERY = 5.minutes
      LQI_STEP = 10
      RENAME_RETRY = 1.minute
      TRANSACTION = "ma-rename-".freeze
      BAD_NAME = %r{[#+]|\A/|/\z|/\d+\z}

      class << self
        def key = Z2m::PROTOCOL
        def icon = "switch-horizontal"

        # Para o local do z2m (Z2M_SITE_ID ou o único), com broker, depois de a ponte
        # ter falado ou de algum aparelho dela existir.
        def available?(site)
          return false if Drivers::Mqtt.url.blank? || ActsAsTenant.without_tenant { Z2m.site } != site

          PairingBridge.exists?(site_id: site.id, protocol: key) || owned(site).exists?
        end

        def owns?(device)
          device.driver == "mqtt" && (device.address.to_h["bridge"] == key || device.external_id.to_s.match?(/\A0x\h{16}\z/))
        end

        def owned(site) = site.devices.where(driver: "mqtt", removed_at: nil).where("devices.address->>'bridge' = ?", key)

        def routers(site)
          owned(site).where("devices.address->'mesh'->>'role' = 'router'").order(:name).map { |d| [ d.name, d.address["friendly_name"] || d.external_id ] }
        end

        def open!(site, seconds, via: nil)
          seconds = seconds.to_i.clamp(1, max_seconds)
          via = via.presence_in(routers(site).map(&:last))
          publish("request/permit_join", { value: true, time: seconds, device: via }.compact)
          b = bridge(site)
          b.update!(permit_until: seconds.seconds.from_now, info: b.info.merge("via" => via).compact)
        end

        def close!(site)
          publish("request/permit_join", { value: false, time: 0 })
          bridge(site).update!(permit_until: nil)
        end

        def request_map!(site)
          publish("request/networkmap", { type: "raw", routes: false })
          bridge(site).update!(network_map_requested_at: Time.current, network_map_error: nil)
        end

        # z2m aceita o ieee no `from`; a transação traz o aparelho de volta na resposta.
        def rename!(device, name)
          publish("request/device/rename", { from: device.external_id, to: name, homeassistant_rename: true, transaction: "#{TRANSACTION}#{device.id}" })
        end

        def name_error(name) = (I18n.t("pairing.errors.bad_name") if name.to_s.match?(BAD_NAME))

        def publish(path, body) = Mqtt::Listener.publish(Z2m.bridge_topic(path), body.to_json)

        # ---- o que chega pelo ouvinte ----

        def receive(site, path, payload)
          ActsAsTenant.with_tenant(site.tenant) do
            if path == "state" then bridge(site).update!(state: state_of(payload))
            elsif (msg = json(payload))
              route(site, path, msg)
            end
          end
        end

        def route(site, path, msg)
          case path
          when "event" then event(site, msg)
          when "info" then info(site, msg)
          when "response/permit_join" then permit_response(site, msg)
          when "response/networkmap" then map_response(site, msg)
          when "response/device/rename" then rename_response(site, msg)
          end
        end

        def event(site, msg)
          data = msg["data"].to_h
          ieee = data["ieee_address"].presence or return
          join = PairingJoin.find_or_initialize_by(site: site, protocol: key, external_id: ieee)
          case msg["type"]
          when "device_joined"
            restart = join.new_record? || join.status.in?(%w[left failed]) || join.resolved?
            join.assign_attributes(status: "joined", joined_at: Time.current, resolution: nil, resolved_at: nil) if restart
          when "device_interview" then interview(join, data)
          when "device_leave" then join.status = "left" if join.persisted?
          else return
          end
          return if join.new_record? && join.joined_at.nil?

          join.name = data["friendly_name"].presence || join.name
          join.save!
        end

        def interview(join, data)
          join.joined_at ||= Time.current
          join.status = { "started" => "interviewing", "successful" => "successful", "failed" => "failed" }.fetch(data["status"].to_s, join.status)
          defn = data["definition"].to_h
          join.assign_attributes(model: defn["model"] || join.model, manufacturer: defn["vendor"] || join.manufacturer,
                                 description: defn["description"] || join.description)
          join.supported = data["supported"] unless data["supported"].nil?
        end

        def info(site, msg)
          b = bridge(site)
          b.update!(state: "online", permit_until: permit_until(msg, b),
                    info: b.info.slice("via").merge("version" => msg["version"], "commit" => msg["commit"],
                                                     "coordinator" => msg["coordinator"].to_h.slice("type", "ieee_address").merge("revision" => msg.dig("coordinator", "meta", "revision")).compact,
                                                     "network" => msg["network"].to_h.slice("channel", "pan_id")).compact)
        end

        # 2.x: permit_join + permit_join_end (ms); 1.x: permit_join_timeout (s) ou aberto sem prazo.
        def permit_until(msg, b)
          return unless msg["permit_join"]
          return Time.zone.at(msg["permit_join_end"].to_f / 1000) if msg["permit_join_end"]
          return msg["permit_join_timeout"].to_i.seconds.from_now if msg["permit_join_timeout"].to_i.positive?

          b.open? ? b.permit_until : max_seconds.seconds.from_now
        end

        def permit_response(site, msg)
          b = bridge(site)
          return b.update!(permit_until: nil, info: b.info.merge("error" => msg["error"].to_s)) if msg["status"] == "error"

          data = msg["data"].to_h
          time = data["time"].to_i
          open = data.key?("value") ? data["value"] && time != 0 : time.positive?
          b.update!(permit_until: open ? (time.positive? ? time : max_seconds).seconds.from_now : nil, info: b.info.except("error"))
        end

        def map_response(site, msg)
          b = bridge(site)
          if msg["status"] == "error"
            b.update!(network_map_error: msg["error"].to_s.first(250), network_map_at: Time.current)
          else
            b.update!(network_map: msg.dig("data", "value").to_h.slice("nodes", "links"), network_map_at: Time.current, network_map_error: nil)
          end
        end

        def rename_response(site, msg)
          return unless msg["status"] == "error"

          tr = msg["transaction"].to_s
          device = site.devices.find_by(id: tr.delete_prefix(TRANSACTION)) if tr.start_with?(TRANSACTION)
          return unless device

          a = device.address.to_h.except("rename_to", "rename_at").merge("rename_error" => msg["error"].to_s.first(250))
          device.bridge_naming = true
          device.update!(name: a["friendly_name"].presence || device.name, address: a)
        end

        def availability(site, topic, payload)
          s = state_of(payload)
          return unless s.in?(%w[online offline])

          ActsAsTenant.with_tenant(site.tenant) { owned(site).where("devices.address->>'topic' = ?", topic).update_all(status: s, updated_at: Time.current) }
        end

        # Aparelho entrou na descoberta: liga ao que entrou pelo assistente e já assina o tópico dele.
        def adopted(site, device, d)
          PairingJoin.where(site: site, protocol: key, external_id: d["ieee_address"]).find_each do |j|
            j.update!(device: device, status: j.status.in?(%w[joined interviewing]) ? "successful" : j.status, power_source: d["power_source"] || j.power_source,
                      model: j.model || d.dig("definition", "model"), manufacturer: j.manufacturer || d.dig("definition", "vendor"))
          end
          retry_rename(device, d["friendly_name"])
          Mqtt::Listener.rescan!
        end

        def retry_rename(device, friendly)
          a = device.address.to_h
          return if a["rename_to"].blank? || a["rename_to"] == friendly
          return if a["rename_at"].present? && Time.zone.parse(a["rename_at"]) > RENAME_RETRY.ago

          device.update_columns(address: a.merge("rename_at" => Time.current.iso8601))
          rename!(device, a["rename_to"])
        rescue Drivers::Mqtt::Error => e
          Rails.logger.warn("[z2m] renome pendente de #{device.id}: #{e.message}")
        end

        def retry_renames(site)
          ActsAsTenant.with_tenant(site.tenant) do
            owned(site).where("devices.address ? 'rename_to'").find_each { |d| retry_rename(d.tap { |x| x.address = x.address.except("rename_at") }, d.address["friendly_name"]) }
          end
        end

        # Sinal de cada mensagem do aparelho, com folga para não gravar a cada mensagem.
        def observe(topic, payload)
          return if !topic.start_with?("#{Z2m.base}/") || topic.start_with?("#{Z2m.base}/bridge/") || !payload.to_s.include?("linkquality")

          lqi = json(payload)&.dig("linkquality")
          return unless lqi.is_a?(Numeric)

          Device.where(driver: "mqtt").where("devices.address->>'topic' = ?", topic).find_each do |d|
            mesh = d.address.to_h["mesh"].to_h
            at = mesh["lqi_at"].present? ? Time.zone.parse(mesh["lqi_at"]) : nil
            next if at && at > LQI_EVERY.ago && (mesh["lqi"].to_i - lqi).abs < LQI_STEP

            d.update_columns(address: d.address.merge("mesh" => mesh.merge("lqi" => lqi.to_i, "lqi_at" => Time.current.iso8601)))
          end
        end

        # Mapa "raw" do z2m → grafo genérico do Pairing::MapLayout.
        def graph(bridge)
          raw = bridge.network_map.to_h
          nodes = Array(raw["nodes"])
          ids = bridge.site.devices.where(driver: "mqtt", external_id: nodes.map { |n| n["ieeeAddr"] }).pluck(:external_id, :id).to_h
          {
            nodes: nodes.filter_map do |n|
              next if n["ieeeAddr"].blank?

              { id: n["ieeeAddr"], name: n["friendlyName"].presence || n["ieeeAddr"], role: Z2m::ROLES[n["type"]] || "end_device",
                device_id: ids[n["ieeeAddr"]], failed: Array(n["failed"]).any? }
            end,
            links: Array(raw["links"]).filter_map do |l|
              a = l["sourceIeeeAddr"] || l.dig("source", "ieeeAddr")
              b = l["targetIeeeAddr"] || l.dig("target", "ieeeAddr")
              { a: a, b: b, lqi: (l["lqi"] || l["linkquality"]).to_i, parent: [ 0, 1 ].include?(l["relationship"]) } if a && b && a != b
            end
          }
        end

        private

        def json(payload)
          v = JSON.parse(payload.to_s)
          v.is_a?(Hash) ? v : nil
        rescue JSON::ParserError
          nil
        end

        def state_of(payload) = (json(payload)&.dig("state") || payload.to_s.strip).to_s.first(20)
      end
    end
  end
end
