module Integrations
  # Assistente "Migre do HA em 10 minutos" por cima do importador
  # (`HomeAssistantImport`): conecta pela URL e um token de acesso longo
  # (guardados na integração `home_assistant`, a mesma do comparador da
  # sombra), lê o HA só para leitura (REST: estados e as configurações das
  # automações, scripts e cenas; WebSocket: os registros de áreas, aparelhos,
  # entidades e etiquetas), mostra o que vai entrar, importa só o escolhido e
  # guarda o relatório. O estado do assistente fica em
  # `integration.settings["migration"]`; os arquivos não ficam guardados (a
  # importação lê de novo).
  module HaMigration
    STATES = %w[fetching preview importing done failed].freeze
    # Registro do HA → [comando do WebSocket, chave no formato do `.storage`].
    REGISTRIES = { "area_registry" => [ "config/area_registry/list", "areas" ], "device_registry" => [ "config/device_registry/list", "devices" ],
                   "entity_registry" => [ "config/entity_registry/list", "entities" ], "label_registry" => [ "config/label_registry/list", "labels" ],
                   "floor_registry" => [ "config/floor_registry/list", "floors" ],
                   "config_entries" => [ "config_entries/get", "entries" ] }.freeze
    MAX_ITEMS = 500
    # HA antigo (antes de 2024.4) não tem andares: segue sem eles.
    OPTIONAL = %w[floor_registry].freeze

    def self.registry_list(transport, name, type)
      Array(transport.ws(type))
    rescue StandardError
      raise unless OPTIONAL.include?(name)

      []
    end

    module_function

    def integration(site) = site.integrations.find_by(driver: "home_assistant")
    def state(integration) = integration&.settings.to_h["migration"].to_h
    def save_state!(integration, values) = integration.update!(settings: integration.settings.merge("migration" => values))

    # Transporte real (SafeHttp + WsClient); os specs trocam por um falso.
    def transport_for(integration) = Transport.new(integration)

    # Lê tudo o que o importador precisa → arquivos no formato dele.
    def fetch(integration, transport: transport_for(integration))
      states = Array(transport.get("/api/states"))
      files = { "states" => states }
      REGISTRIES.each { |name, (type, key)| files[name] = { "data" => { key => registry_list(transport, name, type) } } }
      ids = ->(domain) { states.select { |s| s["entity_id"].to_s.start_with?("#{domain}.") }.first(MAX_ITEMS) }
      autos = ids.("automation").filter_map { |s| (id = s.dig("attributes", "id")) && transport.get("/api/config/automation/config/#{CGI.escape(id.to_s)}") }
      scripts = ids.("script").to_h { |s| (k = s["entity_id"].split(".", 2).last) && [ k, transport.get("/api/config/script/config/#{CGI.escape(k)}") ] }
      scenes = ids.("scene").filter_map { |s| (id = s.dig("attributes", "id")) && transport.get("/api/config/scene/config/#{CGI.escape(id.to_s)}") }
      files.merge("automations" => autos.select { |a| a.is_a?(Hash) }.to_yaml, "scripts" => scripts.select { |_, v| v.is_a?(Hash) }.to_yaml,
                  "scenes" => scenes.select { |s| s.is_a?(Hash) }.to_yaml)
    end

    # O que vai entrar, para a tela de revisão (sem gravar nada).
    def preview(site, files)
      reg = ->(name, key) { Array(files.dig(name, "data", key)) }
      areas = reg.("area_registry", "areas").map { |a| a["name"].to_s }
      have = site.areas.pluck(:name).map(&:downcase)
      ext = site.devices.where.not(external_id: [ nil, "" ]).pluck(:external_id).to_set
      devices = reg.("device_registry", "devices")
      matched = devices.count { |d| Array(d["identifiers"]).any? { |_, v| ext.include?(v.to_s) || ext.include?(v.to_s.split("_", 2).last) } }
      states = Array(files["states"])
      helpers = states.filter_map { |s| (d = s["entity_id"].to_s.split(".").first) && HomeAssistantImport::HELPERS.key?(d) && s }
      doc = ->(k) { YAML.safe_load(files[k].to_s, aliases: false) || [] }
      autos = Array(doc.("automations")).map do |a|
        on = states.find { |s| s["entity_id"].start_with?("automation.") && s.dig("attributes", "id").to_s == a["id"].to_s }&.dig("state") == "on"
        { "id" => a["id"].to_s, "name" => a["alias"].presence || "Automação #{a['id']}", "enabled" => on }
      end
      { "areas" => { "total" => areas.size, "new" => areas.count { |n| !have.include?(n.downcase) }, "names" => areas.first(40) },
        "devices" => { "total" => devices.size, "matched" => matched },
        "entities" => reg.("entity_registry", "entities").count { |e| e["disabled_by"].blank? },
        "helpers" => helpers.group_by { |s| s["entity_id"].split(".").first }.transform_values(&:size),
        "automations" => autos,
        "scripts" => doc.("scripts").to_h.map { |k, v| { "id" => k.to_s, "name" => v.to_h["alias"].presence || k.to_s.humanize } },
        "scenes" => Array(doc.("scenes")).map { |s| { "id" => s["id"].to_s, "name" => s["name"].presence || "Cena #{s['id']}" } } }
    end

    # Só o escolhido: automações, scripts e cenas pelos ids; helpers sim/não.
    def select(files, choice)
      pick = ->(k) { Array(choice[k]).map(&:to_s) }
      doc = ->(k) { YAML.safe_load(files[k].to_s, aliases: false) }
      out = files.dup
      out["automations"] = Array(doc.("automations")).select { |a| pick.("automations").include?(a["id"].to_s) }.to_yaml
      out["scripts"] = doc.("scripts").to_h.select { |k, _| pick.("scripts").include?(k.to_s) }.to_yaml
      out["scenes"] = Array(doc.("scenes")).select { |s| pick.("scenes").include?(s["id"].to_s) }.to_yaml
      unless choice["helpers"]
        out["states"] = Array(files["states"]).reject { |s| HomeAssistantImport::HELPERS.key?(s["entity_id"].to_s.split(".").first) || s.dig("attributes", "entity_id").is_a?(Array) }
        out["config_entries"] = { "data" => { "entries" => [] } }
      end
      out
    end

    # Importa o escolhido com o progresso no estado. → relatório.
    def run!(integration, choice, transport: transport_for(integration))
      site = integration.site
      files = select(fetch(integration, transport: transport), choice)
      step = lambda do |i, label, total|
        save_state!(integration, state(integration).merge("progress" => { "i" => i, "label" => label, "total" => total }))
      end
      r = HomeAssistantImport.call(site, files.transform_values { |v| v.is_a?(String) ? v : v.to_json }, progress: step)
      mapped = ExternalRef.map_for(site, HomeAssistantImport::SOURCE).keys.to_set
      missing = Array(files.dig("device_registry", "data", "devices")).reject { |d| mapped.include?("device:#{d['id']}") }
      report(r, missing)
    end

    # Resultado do importador → o que veio, o que virou blueprint e o que ficou de fora (e por quê).
    def report(r, missing_devices = [])
      items = r.items
      left = missing_devices.first(200).map { |d| { "what" => d["name_by_user"].presence || d["name"].to_s, "why" => "aparelho do HA sem equivalente aqui: adicione a integração dele (Tuya, Xiaomi, MQTT…) e importe de novo" } } +
             r.unmapped.first(200).map { |e| { "what" => e, "why" => "entidade sem ponto equivalente no aparelho daqui" } } +
             r.helpers_skipped.map { |h| e, why = h.split(": ", 2); { "what" => e, "why" => why.to_s } } +
             r.scenes.flat_map { |s| Array(s["lost"]).map { |e| { "what" => "#{s['name']}: #{e}", "why" => "entidade da cena sem ponto equivalente" } } } +
             items.select { |i| i["notes"].to_a.any? { |n| n.start_with?("não importou") } }.map { |i| { "what" => i["name"], "why" => i["notes"].first } }
      { "came" => { "areas" => r.areas, "devices_added" => r.devices_added, "devices_moved" => r.devices_moved, "entities" => r.entities,
                    "helpers" => r.helpers, "scenes" => r.scenes.size, "tags" => r.tags,
                    "automations" => items.count { |i| i["kind"] == "automation" }, "scripts" => items.count { |i| i["kind"] == "script" } },
        "blueprints" => items.map { |i| i.slice("kind", "name", "lossless", "enabled").merge("notes" => Array(i["notes"]).first(4)) },
        "left_out" => left }
    end

    # REST pelo SafeHttp (o mesmo do comparador) e WebSocket para os registros.
    class Transport
      def initialize(integration)
        @integration = integration
      end

      def get(path) = HomeAssistantPlugin.get(@integration, path)

      # ponytail: o WebSocket checa o endereço no SafeHttp mas conecta pelo nome (sem prender o IP como o HTTP faz).
      def ws(type, **params)
        uri = URI.parse(@integration.settings["url"].to_s)
        SafeHttp.check!(uri.host)
        url = "#{uri.scheme == 'https' ? 'wss' : 'ws'}://#{uri.host}:#{uri.port}/api/websocket"
        WsClient.open(url, timeout: 15) do |ws|
          ws.read_json # auth_required
          ws.send_json(type: "auth", access_token: @integration.secrets["token"])
          raise Integrations::Error, "token recusado" unless ws.read_json&.dig("type") == "auth_ok"

          ws.send_json({ id: 1, type: type }.merge(params))
          loop do
            msg = ws.read_json(30) or raise Integrations::Error, "o HA não respondeu #{type}"
            next unless msg["id"] == 1

            raise Integrations::Error, msg.dig("error", "message").to_s.truncate(120) unless msg["success"]

            return msg["result"]
          end
        end
      rescue WsClient::Error, SafeHttp::Error, JSON::ParserError => e
        raise Integrations::Error, e.message.truncate(120)
      end
    end
  end
end
