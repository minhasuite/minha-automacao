module Pairing
  # Saúde da rede de malha de um adaptador no local: uma linha por aparelho
  # da ponte (papel, alimentação, sinal, último visto, bateria, situação) e o
  # resumo. Sinal (linkquality 0–255): bom a partir de GOOD, fraco abaixo de WEAK.
  module Network
    GOOD = 100
    WEAK = 40
    LOW_BATTERY = 20
    STALE = 25.hours

    Row = Data.define(:device, :role, :power, :lqi, :lqi_at, :seen_at, :battery, :situation) do
      def weak? = !lqi.nil? && lqi < WEAK
      def low_battery? = !battery.nil? && battery < LOW_BATTERY
      def stale? = seen_at.nil? || seen_at < STALE.ago
      def problem? = weak? || low_battery? || situation == "offline"
      def id = device.id
    end

    module_function

    def rows(site, adapter)
      devices = adapter.owned(site).includes(:area).order(:name).to_a
      battery = Point.where(id: devices.filter_map(&:battery_point_id)).pluck(:id, :value).to_h
      devices.map do |d|
        mesh = Pairing.mesh(d)
        b = battery[d.battery_point_id]
        Row.new(device: d, role: mesh["role"] || "end_device", power: mesh["power"], lqi: mesh["lqi"], lqi_at: (Time.zone.parse(mesh["lqi_at"]) if mesh["lqi_at"]),
                seen_at: d.last_seen_at, battery: b.is_a?(Numeric) ? b.round : nil, situation: d.situation)
      end
    end

    def summary(rows)
      { total: rows.size, routers: rows.count { |r| r.role == "router" }, ends: rows.count { |r| r.role == "end_device" },
        weak: rows.count(&:weak?), low_battery: rows.count(&:low_battery?), offline: rows.count { |r| r.situation == "offline" } }
    end

    # Ordem da tabela (?sort=): nome, papel, sinal, visto, bateria.
    SORTS = {
      "name" => ->(r) { r.device.name.downcase },
      "role" => ->(r) { [ r.role, r.device.name.downcase ] },
      "lqi" => ->(r) { r.lqi || -1 },
      "seen" => ->(r) { r.seen_at&.to_i || 0 },
      "battery" => ->(r) { r.battery || 101 }
    }.freeze

    def sort(rows, key, dir)
      sorted = rows.sort_by(&SORTS.fetch(key.to_s, SORTS["name"]))
      dir.to_s == "desc" ? sorted.reverse : sorted
    end
  end
end
