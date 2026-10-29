module Miio
  # Robô Xiaomi para um local: {name, host, token, did, model, area, rooms:
  # [{id, name}]} (token pela entrada padrão, nunca em arquivo). Idempotente
  # pelo did: de novo atualiza host, token e cômodos e cria só os pontos que
  # faltam (pela chave siid/piid/papel).
  module Import
    AREA = "Importados do HA".freeze

    module_function

    def call(site, data)
      did = data.fetch("did").to_s
      device = site.devices.find_or_initialize_by(driver: "xiaomi_miot", external_id: did)
      created = device.new_record?
      area = site.areas.find_by(name: data["area"]) if data["area"].present?
      device.assign_attributes(name: device.name.presence || data["name"].presence || "Robô aspirador",
                               area: device.area || area || site.areas.find_or_create_by!(name: AREA),
                               manufacturer: "Xiaomi", model: data["model"], address: device.address.merge("host" => data.fetch("host"), "model" => data["model"]).compact)
      device.credential = data["token"] if data["token"].present?
      rooms = Array(data["rooms"]).map { |r| { "id" => Integer(r["id"]), "name" => r["name"].to_s.squish } }
      points = 0
      ActiveRecord::Base.transaction do
        device.save!
        Vacuum.points(rooms).each do |attrs|
          a = attrs[:address]
          existing = device.points.find { |p| p.address.values_at("siid", "piid", "role") == a.values_at("siid", "piid", "role") }
          next existing.update!(address: existing.address.merge(a)) if existing

          device.points.create!(site: site, **attrs)
          points += 1
        end
      end
      { device: created ? 1 : 0, points: points }
    end
  end
end
