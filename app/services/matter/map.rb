module Matter
  # Nó do python-matter-server → aparelho e pontos, pelo mapa de dados
  # `config/device_maps/matter.yml` ("cluster/atributo" → ponto). Nada aqui
  # conhece marca ou modelo. Conversão nova = linha em CONVERT ([do bruto, para o bruto]).
  module Map
    CONVERT = {
      "not" => [ ->(r) { !r }, ->(v) { !v } ],
      "bit0" => [ ->(r) { r.to_i.anybits?(1) }, ->(v) { v ? 1 : 0 } ],
      "lux" => [ ->(r) { r.to_i.positive? ? (10**((r.to_i - 1) / 10_000.0)).round(1) : 0 }, ->(v) { (10_000 * Math.log10(v.to_f) + 1).round } ],
      "inverted_100ths" => [ ->(r) { 100 - (r.to_i / 100.0).round }, ->(v) { ((100 - v.to_f) * 100).round } ]
    }.freeze
    POINT_KEYS = %w[name capability unit device_class scale min max].freeze

    module_function

    def data = @data ||= YAML.load_file(Rails.root.join("config/device_maps/matter.yml"))
    def spec(point) = data["attributes"]["#{point.address['cluster']}/#{point.address['attribute']}"]

    # Nó → entrada do inventário (formato de `Integrations`).
    def entry(node)
      attrs = node["attributes"].to_h
      id = node["node_id"].to_s
      { "id" => id, "kind" => "matter", "name" => data["names"].filter_map { |k| attrs[k].presence }.first || "Matter #{id}",
        "manufacturer" => attrs[data["vendor"]], "model" => attrs[data["model"]], "category" => "Matter", "online" => node["available"] != false,
        "address" => { "node" => node["node_id"] }, "poll_s" => 1800, "points" => points(node) }
    end

    def points(node)
      found = node["attributes"].to_h.keys.filter_map do |path|
        ep, cluster, attribute = path.split("/").map(&:to_i)
        s = data["attributes"]["#{cluster}/#{attribute}"]
        [ ep, cluster, attribute, s ] if s && ep.positive?
      end
      counts = found.map { |_, c, a, _| [ c, a ] }.tally
      found.sort.map do |ep, cluster, attribute, s|
        attrs = s.slice(*POINT_KEYS)
        attrs["name"] = "#{s['name']} #{ep}" if counts[[ cluster, attribute ]] > 1
        attrs["writable"] = s["commands"].present?
        attrs.merge("address" => { "node" => node["node_id"], "endpoint" => ep, "cluster" => cluster, "attribute" => attribute })
      end
    end

    def path(point) = point.address.values_at("endpoint", "cluster", "attribute").join("/")

    # ondaC1 (C3): quem mais controla o nó (multi-admin), pela lista de fabrics
    # do Operational Credentials (0/62/1, campo 2 = vendor id).
    VENDORS = { 4937 => "apple", 24_582 => "google", 4631 => "amazon", 4362 => "samsung", 65_521 => "test" }.freeze
    def fabrics(node)
      Array(node.dig("attributes", "0/62/1")).filter_map do |f|
        v = f.is_a?(Hash) && (f["2"] || f["vendorID"] || f["vendor_id"])
        VENDORS.fetch(v.to_i, format("0x%04X", v.to_i)) if v
      end.uniq
    end

    # Bruto do servidor → valor do ponto.
    def value(point, raw)
      return if raw.nil?

      raw = CONVERT.fetch(spec(point)["convert"]).first.call(raw) if spec(point)&.dig("convert")
      point.from_raw(raw)
    end

    # Valor do ponto → bruto do comando.
    def raw(point, value)
      raw = point.to_raw(value)
      (c = spec(point)&.dig("convert")) ? CONVERT.fetch(c).last.call(value) : raw
    end

    # Grava o estado do nó nos pontos do aparelho (fora do ar = indisponível).
    def apply(device, node)
      return Drivers::Matter.unavailable!(device) if node["available"] == false

      attrs = node["attributes"].to_h
      device.update_columns(status: "online", last_seen_at: Time.current)
      device.points.each do |p|
        v = value(p, attrs[path(p)])
        p.report!(v) unless v.nil?
      end
    end
  end
end
