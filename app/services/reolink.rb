# Reolink (integ): câmera ou NVR pela API HTTP do aparelho (`/api.cgi`, login
# com token de 1 h). Detecção nativa (pessoa, veículo, animal; `GetAiState`)
# vira sensores "na câmera agora" e, quando um tipo acende, uma detecção
# genérica (Detections) no ponto do canal. Movimento comum pelo `GetMdState`.
# Só leitura (a cada 5 s); quadro pelo `Snap`.
module Reolink
  AI = { "people" => "person", "vehicle" => "vehicle", "dog_cat" => "animal", "face" => "face", "package" => "package" }.freeze

  module_function

  def conn(integration)
    s = integration.settings
    port = (s["port"].presence || 80).to_i
    { id: integration.id, base: "#{port == 443 ? 'https' : 'http'}://#{s['host']}:#{port}", user: s["username"].presence || "admin",
      password: integration.secrets["password"].to_s }
  end

  # ponytail: token por integração na memória do processo; refaz o login quando vence ou o aparelho recusa.
  def tokens = (@tokens ||= {})

  def token(c)
    tok, exp = tokens[c[:id]]
    return tok if tok && exp > Time.current

    r = Array(LanHttp.post("#{c[:base]}/api.cgi?cmd=Login", [ { "cmd" => "Login", "param" => { "User" => { "Version" => "0", "userName" => c[:user], "password" => c[:password] } } } ], insecure: true)).first.to_h
    t = r.dig("value", "Token") or raise Integrations.auth(Integrations::Error.new("Usuário ou senha do Reolink não conferem."))
    tokens[c[:id]] = [ t["name"], Time.current + [ t["leaseTime"].to_i - 60, 60 ].max.seconds ]
    t["name"]
  end

  def cmd(c, name, param = {}, again: true)
    r = Array(LanHttp.post("#{c[:base]}/api.cgi?cmd=#{name}&token=#{token(c)}", [ { "cmd" => name, "action" => 0, "param" => param } ], insecure: true)).first.to_h
    return r["value"] || {} if r["code"].to_i.zero?

    tokens.delete(c[:id])
    return cmd(c, name, param, again: false) if again && r.dig("error", "rspCode").to_i == -6 # sessão vencida

    raise Integrations::Error, "O Reolink recusou #{name}: #{r.dig('error', 'detail') || r['code']}"
  end

  # Um aparelho por canal (câmera = 1; NVR = um por câmera).
  def inventory(integration)
    c = conn(integration)
    info = cmd(c, "GetDevInfo")["DevInfo"].to_h
    channels = info["channelNum"].to_i.clamp(1, 64)
    (0...channels).map do |ch|
      ai = cmd(c, "GetAiState", { "channel" => ch })
      kinds = AI.select { |k, _| ai.dig(k, "support").to_i == 1 }
      name = [ info["name"].presence || "Reolink", ("canal #{ch + 1}" if channels > 1) ].compact.join(" ")
      { "id" => "reolink:#{info['serial'].presence || integration.settings['host']}:#{ch}", "kind" => "reolink", "name" => name, "manufacturer" => "Reolink",
        "model" => info["model"], "category" => "Câmera", "online" => true, "poll_s" => 5, "address" => { "channel" => ch },
        "points" => [ Detections.point("channel" => ch), { "name" => "Movimento", "capability" => "motion", "address" => { "channel" => ch, "ai" => "md" } },
                      *kinds.map { |k, kind| Detections.presence(kind, "channel" => ch, "ai" => k) } ] }
    end
  end

  # Sensores do canal; tipo de IA que acendeu agora vira detecção.
  def poll(device)
    c = conn(device.integration)
    ch = device.address["channel"].to_i
    ai = cmd(c, "GetAiState", { "channel" => ch })
    md = cmd(c, "GetMdState", { "channel" => ch })["state"].to_i == 1
    device.update_columns(status: "online", last_seen_at: Time.current)
    lit = nil
    device.points.select { |p| p.capability == "motion" && !p.disabled }.each do |p|
      key = p.address["ai"]
      on = key == "md" ? md : ai.dig(key, "alarm_state").to_i == 1
      lit ||= key if on && key != "md" && p.value != true
      p.report!(on)
    end
    det = device.points.find { |p| p.capability == "detection" && !p.disabled }
    det&.report!(Detections.value(label: AI.fetch(lit), id: "#{ch}-#{Time.current.to_i}")) if lit
  end

  def unavailable!(device) = Drivers.offline!(device)

  def snapshot(point)
    c = conn(point.device.integration)
    LanHttp.get("#{c[:base]}/cgi-bin/api.cgi?cmd=Snap&channel=#{point.device.address['channel'].to_i}&rs=#{SecureRandom.hex(4)}&token=#{token(c)}", raw: true, insecure: true)
  end
end
