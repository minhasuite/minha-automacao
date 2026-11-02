# UniFi Protect (integ): console UniFi (UDM, UNVR, Cloud Key) pela API local
# do Protect (login com usuário local; cookie + CSRF). Cada câmera vira
# aparelho com movimento, sensores de detecção inteligente (pessoa, veículo,
# animal, encomenda) e o ponto de detecção genérico (Detections), lido a
# cada 5 s pelos eventos `smartDetectZone`. Quadro pelo `/snapshot`.
module UnifiProtect
  API = "/proxy/protect/api".freeze
  MOTION_S = 30 # movimento "agora" = último há menos que isso

  module_function

  def conn(integration)
    s = integration.settings
    port = (s["port"].presence || 443).to_i
    { id: integration.id, base: "https://#{s['host']}#{":#{port}" unless port == 443}", user: s["username"].to_s, password: integration.secrets["password"].to_s }
  end

  # ponytail: sessão por integração na memória do processo; 401 refaz o login uma vez.
  def sessions = (@sessions ||= {})

  def session(c)
    sessions[c[:id]] ||= begin
      cookie = csrf = nil
      LanHttp.call(:post, "#{c[:base]}/api/auth/login", body: { username: c[:user], password: c[:password], rememberMe: true }, insecure: true) do |res|
        cookie = Array(res.get_fields("set-cookie")).map { |v| v.split(";").first }.join("; ")
        csrf = res["x-csrf-token"]
      end
      { "Cookie" => cookie, "X-CSRF-Token" => csrf }.compact
    end
  end

  def get(c, path, raw: false, again: true)
    LanHttp.get("#{c[:base]}#{API}#{path}", headers: session(c), raw: raw, insecure: true)
  rescue Integrations::AuthError
    sessions.delete(c[:id])
    raise unless again

    get(c, path, raw: raw, again: false)
  end

  def inventory(integration)
    get(conn(integration), "/bootstrap").fetch("cameras", []).map do |cam|
      id = cam["id"]
      kinds = Array(cam.dig("featureFlags", "smartDetectTypes"))
      { "id" => "unifi:#{cam['mac'].presence || id}", "kind" => "unifi_protect", "name" => cam["name"].presence || "Câmera UniFi", "manufacturer" => "Ubiquiti",
        "model" => cam["marketName"] || cam["type"], "category" => "Câmera", "online" => cam["isConnected"] != false, "poll_s" => 5, "address" => { "camera" => id },
        "points" => [ Detections.point("camera" => id), { "name" => "Movimento", "capability" => "motion", "address" => { "camera" => id, "label" => "motion" } },
                      *kinds.map { |k| Detections.presence(k, "camera" => id, "label" => k) } ] }
    end
  end

  def poll(device)
    c = conn(device.integration)
    id = device.address["camera"]
    cam = get(c, "/cameras/#{id}")
    now = (Time.current.to_f * 1000).to_i
    events = get(c, "/events?#{URI.encode_www_form(start: now - 60_000, end: now, types: 'smartDetectZone', cameras: id)}")
    ev = Array(events).select { |e| e["camera"] == id }.max_by { |e| e["start"].to_i }
    live = ev && ev["end"].nil? ? Array(ev["smartDetectTypes"]) : []
    motion = cam["isMotionDetected"] == true || cam["lastMotion"].to_i > now - (MOTION_S * 1000)
    device.update_columns(status: cam["isConnected"] == false ? "offline" : "online", last_seen_at: Time.current)
    device.points.reject(&:disabled).each do |p|
      case p.capability
      when "motion" then p.report!(p.address["label"] == "motion" ? motion : live.include?(p.address["label"]))
      when "detection" then report_event(p, ev) if ev
      end
    end
  end

  def report_event(point, ev)
    return if ev["id"].to_s == (point.value.is_a?(Hash) ? point.value["id"] : nil)

    point.report!(Detections.value(label: Array(ev["smartDetectTypes"]).first || "motion", score: ev["score"], id: ev["id"], at: Time.zone.at(ev["start"].to_i / 1000.0)))
  end

  def unavailable!(device) = Drivers.offline!(device)

  def snapshot(point) = get(conn(point.device.integration), "/cameras/#{point.device.address['camera']}/snapshot", raw: true)
end
