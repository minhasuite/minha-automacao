# Frigate (integ): NVR com IA (pessoa, carro, animal…) pela API HTTP
# (/api/config, /api/events, quadro e clipe) e, com broker, pelo MQTT
# (`<tópico>/events` e `<tópico>/<câmera>/<rótulo>` com a contagem). Cada
# câmera vira um aparelho `frigate` com o ponto de detecção (Detections) e um
# sensor "Pessoa na câmera" por objeto rastreado. A leitura (10 s) cobre quem
# não tem broker; a mesma detecção não conta duas vezes (id + zonas).
module Frigate
  FRESH = 2.minutes # detecção mais velha que isso não dispara (primeira leitura, volta do ar)

  module_function

  def inventory(base)
    LanHttp.get("#{base}/api/config").fetch("cameras", {}).filter_map do |name, cam|
      next if cam["enabled"] == false

      labels = Array(cam.dig("objects", "track")).presence || %w[person]
      { "id" => "frigate:#{name}", "kind" => "frigate", "name" => name.tr("_", " ").capitalize, "manufacturer" => "Frigate", "model" => "Câmera com IA",
        "category" => "Câmera", "online" => true, "poll_s" => 10, "address" => { "camera" => name, "zones" => cam.fetch("zones", {}).keys },
        "points" => [ Detections.point("camera" => name), *labels.map { |l| Detections.presence(l, "camera" => name, "label" => l) } ] }
    end
  end

  def base_of(device) = device.integration&.settings&.dig("url") || raise(Integrations::Error, "Integração do Frigate removida.")

  def value(base, ev)
    id = ev["id"]
    score = (ev["top_score"] || ev["score"] || ev.dig("data", "top_score")).to_f * 100
    Detections.value(label: ev["label"], score: score, zones: ev["entered_zones"] || ev["zones"], id: id, at: Time.zone.at(ev["start_time"].to_f),
                     clip: (ev["has_clip"] ? "#{base}/api/events/#{id}/clip.mp4" : nil))
  end

  # Detecção nova (id ou zonas diferentes do último aviso) e recente.
  def report_event(point, base, ev)
    v = value(base, ev)
    cur = point.value.is_a?(Hash) ? point.value : {}
    return if (v["id"] == cur["id"] && v["zones"] == cur["zones"]) || Time.zone.at(ev["start_time"].to_f) < FRESH.ago

    point.report!(v)
  end

  # Leitura periódica (Polling): a última detecção e o que a câmera vê agora.
  def poll(device)
    base = base_of(device)
    cam = device.address["camera"]
    last = LanHttp.get("#{base}/api/events?#{URI.encode_www_form(camera: cam, limit: 1)}").first
    live = LanHttp.get("#{base}/api/events?#{URI.encode_www_form(camera: cam, in_progress: 1, limit: 50)}").map { |e| e["label"] }
    device.update_columns(status: "online", last_seen_at: Time.current)
    device.points.reject(&:disabled).each do |p|
      p.capability == "detection" ? (last && report_event(p, base, last)) : p.report!(live.include?(p.address["label"]))
    end
  end

  def unavailable!(device) = Drivers.offline!(device)

  # Quadro da detecção de agora (com a caixa) ou o último da câmera.
  def snapshot(point)
    base = base_of(point.device)
    id = point.value.is_a?(Hash) && point.value["id"]
    LanHttp.get(id ? "#{base}/api/events/#{id}/snapshot.jpg?bbox=1" : "#{base}/api/#{point.device.address['camera']}/latest.jpg", raw: true)
  end

  # --- MQTT (Mqtt::Listener::DISCOVERY) ---------------------------------------

  def prefixes = Integration.where(driver: "frigate").map { |i| i.settings["topic"].presence || "frigate" }.uniq
  def topics = prefixes.flat_map { |t| [ "#{t}/events", "#{t}/+/+" ] }
  def handles?(topic) = prefixes.any? { |t| topic.start_with?("#{t}/") }

  def handle(topic, payload)
    prefix, *rest = topic.split("/")
    if rest == [ "events" ]
      msg = JSON.parse(payload)
      ev = msg["after"] or return
      return unless %w[new update].include?(msg["type"])

      each_device(prefix, ev["camera"]) { |d| (p = d.points.find { |x| x.capability == "detection" && !x.disabled }) && report_event(p, base_of(d), ev) }
    elsif rest.size == 2 && payload.to_s.strip.match?(/\A\d+\z/)
      camera, label = rest
      each_device(prefix, camera) { |d| d.points.select { |x| x.capability == "motion" && x.address["label"] == label }.each { |p| p.report!(payload.to_i.positive?) } }
    end
  rescue JSON::ParserError
    nil
  end

  def each_device(prefix, camera)
    Device.where(driver: "frigate", disabled: false, removed_at: nil).where("address->>'camera' = ?", camera.to_s).includes(:integration, :points).find_each do |d|
      next unless (d.integration&.settings&.dig("topic").presence || "frigate") == prefix

      ActsAsTenant.with_tenant(d.tenant) { yield d }
    end
  end
end
