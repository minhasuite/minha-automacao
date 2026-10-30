module Tuya
  # Importa os aparelhos do LocalTuya (HA, `core.config_entries` →
  # data.devices) para um local, na área "Importados do HA". Idempotente pelo
  # device_id: rodar de novo atualiza host, versão e local_key e cria só os
  # pontos que faltam. `listen` nasce desligado.
  class Import
    AREA = "Importados do HA".freeze
    # Atributos de tomada com medição no LocalTuya → ponto de medição.
    MEASURES = {
      "current" => { name: "Corrente", unit: "A", device_class: "current", scale: "0.001" },
      "current_consumption" => { name: "Potência", unit: "W", device_class: "power", scale: "0.1" },
      "voltage" => { name: "Tensão", unit: "V", device_class: "voltage", scale: "0.1" }
    }.freeze
    RISKY = /port[aã]o|sirene/i

    Result = Struct.new(:devices, :points, :skipped, keyword_init: true)

    def self.call(site, data) = new(site, data).call

    # `core.config_entries` inteiro do HA → aparelhos de todas as entradas do LocalTuya.
    def self.from_config_entries(data)
      entries = Array(data.is_a?(Hash) ? data.dig("data", "entries") : nil).select { |e| e["domain"] == "localtuya" }
      entries.flat_map { |e| e.dig("data", "devices").then { |d| d.is_a?(Hash) ? d.values : Array(d) } }
    end

    def initialize(site, data)
      @site = site
      @devices = (data.is_a?(Hash) && data.key?("devices") ? data["devices"] : data)
      @devices = @devices.values if @devices.is_a?(Hash)
    end

    def call
      result = Result.new(devices: 0, points: 0, skipped: [])
      area = @site.areas.find_or_create_by!(name: AREA)
      Array(@devices).each do |d|
        ActiveRecord::Base.transaction { import_device(area, d, result) }
      end
      result
    end

    # Entidade do LocalTuya ({platform, id, friendly_name, brightness…}) →
    # atributos de ponto. A varredura da Tuya na nuvem monta a mesma entidade.
    def self.specs_for(e)
      name = e["friendly_name"].to_s.split("|").last.to_s.strip.presence || "Ponto #{e['id']}"
      case e["platform"]
      when "switch" then [ onoff(name, e) ] + measures(e)
      when "light" then [ onoff(name, e), dimmer(name, e) ].compact
      else []
      end
    end

    def self.onoff(name, e)
      risky = name.match?(RISKY) || e["device_name"].to_s.match?(RISKY)
      { name: name, capability: "onoff", address: { "dps" => e["id"].to_s },
        risk: risky ? "critical" : "normal", confirm: (risky ? "Acionar #{name}?" : nil) }
    end

    def self.dimmer(name, e)
      return unless e["brightness"]

      upper = (e["brightness_upper"].presence || 1000).to_d
      lower = (e["brightness_lower"].presence || 10).to_d
      { name: "#{name} (brilho)", capability: "dimmer", address: { "dps" => e["brightness"].to_s },
        scale: 100 / upper, min: [ (lower * 100 / upper).ceil, 1 ].max, max: 100 }
    end

    def self.measures(e)
      MEASURES.filter_map do |attr, m|
        next unless e[attr]

        { name: m[:name], capability: "measure", address: { "dps" => e[attr].to_s }, unit: m[:unit],
          device_class: m[:device_class], state_class: "measurement", scale: e["#{attr}_scale"] || m[:scale] }
      end
    end

    private

    def import_device(area, d, result)
      device = @site.devices.find_or_initialize_by(driver: "tuya_local", external_id: d.fetch("device_id"))
      device.area ||= area
      device.name = d["friendly_name"].presence || d["device_id"] if device.new_record?
      device.address = device.address.merge("host" => d.fetch("host"), "version" => d["protocol_version"].presence || "3.3")
      device.credential = d.fetch("local_key")
      device.manufacturer ||= "Tuya"
      device.save!
      result.devices += 1

      Array(d["entities"]).each do |e|
        specs = self.class.specs_for(e)
        result.skipped << "#{device.name}: #{e['platform']} (dps #{e['id']})" if specs.empty?
        specs.each do |spec|
          next if device.points.any? { |p| p.address["dps"].to_s == spec[:address]["dps"] }

          device.points.create!(spec)
          result.points += 1
        end
      end
    end
  end
end
