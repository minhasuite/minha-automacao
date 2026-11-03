# Máquina onde o produto roda (ondaA2 A13/A19), lida pelo supervisor
# (`GET /system/host`, sonda em supervisor/host_probe.rb): sistema, memória,
# rede, vizinhos da rede (o DHCP do roteador), portas seriais e USB. Sem
# supervisor (VPS, dev) tudo vem vazio e a tela diz por quê.
module Host
  CACHE_S = 30

  module_function

  def available? = Apps::Supervisor.configured?

  # → Hash com chaves em texto (vazio sem supervisor ou com ele fora do ar).
  def info(refresh: false)
    return {} unless available?

    Rails.cache.delete("host:info") if refresh
    Rails.cache.fetch("host:info", expires_in: CACHE_S.seconds) { Apps::Supervisor.request(:get, "/system/host").fetch("data") }
  rescue Apps::Supervisor::Error => e
    Rails.logger.warn("[host] #{e.message}")
    {}
  end

  ACTIONS = { "reboot" => "/system/host/reboot", "shutdown" => "/system/host/shutdown" }.freeze

  def power!(action, user:)
    path = ACTIONS.fetch(action)
    AuditEvent.create!(tenant_id: user.tenant_id, user_id: user.id, action: "host.#{action}", auditable_type: "Host", details: {})
    Apps::Supervisor.request(:post, path)
  end

  # ---- Descoberta (A19): o plugin declara `dhcp` e `usb` como no manifesto do HA ----

  # Vizinhos da rede que casam com {hostname: "shelly*", mac: "A4CF12"} → formato do Mdns.browse.
  def dhcp(matchers)
    return [] if matchers.blank?

    neighbors.select { |n| matchers.any? { |m| dhcp_match?(m, n) } }.map do |n|
      { "name" => n["hostname"].presence&.sub(/\..*/, "") || n["ip"], "host" => n["ip"], "port" => nil,
        "txt" => { "mac" => n["mac"], "hostname" => n["hostname"], "via" => "dhcp" }.compact }
    end
  end

  # Vizinhos da sonda do host (ARP + DNS reverso) mais o que o dhcp-watch ouviu
  # (o nome que o próprio aparelho pediu vale mais que o do roteador).
  def neighbors
    heard = leases.values
    by_mac = heard.index_by { |l| l["mac"] }
    arp = Array(info["neighbors"]).map { |n| (l = by_mac[n["mac"].to_s.upcase]) ? n.merge("hostname" => l["hostname"].presence || n["hostname"]) : n }
    arp + heard.reject { |l| arp.any? { |n| n["mac"].to_s.casecmp?(l["mac"]) } || l["ip"].blank? }.map { |l| l.slice("ip", "mac", "hostname") }
  end

  # ---- DHCP passivo (resto, 7.23): bin/dhcp-watch → POST /api/v1/dhcp/leases ----
  LEASES_TTL = 7.days
  MAX_LEASES = 500

  def leases_key(tenant_id = ActsAsTenant.current_tenant&.id) = "dhcp:leases:#{tenant_id}"
  def leases(tenant_id = ActsAsTenant.current_tenant&.id) = Rails.cache.read(leases_key(tenant_id)) || {}

  def store_leases!(tenant, list)
    seen = leases(tenant.id)
    n = Array(list).first(200).count do |l|
      mac = l["mac"].to_s.upcase
      next false unless mac.match?(/\A\h\h(:\h\h){5}\z/)

      seen[mac] = (seen[mac] || {}).merge(l.slice("hostname", "ip", "vendor").compact_blank).merge("mac" => mac, "at" => Time.current.iso8601)
      true
    end
    Rails.cache.write(leases_key(tenant.id), seen.sort_by { |_, v| v["at"] }.last(MAX_LEASES).to_h, expires_in: LEASES_TTL)
    n
  end

  def dhcp_match?(m, n)
    mac = n["mac"].to_s.delete(":-").upcase
    (m[:mac].nil? || mac.start_with?(m[:mac].to_s.delete(":-").upcase)) &&
      (m[:hostname].nil? || File.fnmatch?(m[:hostname], n["hostname"].to_s.downcase))
  end

  # Portas seriais que casam com {vid: "10C4", pid: "EA60", description: "*zigbee*"}.
  def usb(matchers)
    return [] if matchers.blank?

    Array(info["serial"]).select { |s| matchers.any? { |m| usb_match?(m, s) } }.map do |s|
      { "name" => [ s["manufacturer"], s["product"] ].compact_blank.join(" ").presence || s["id"], "host" => nil, "port" => nil,
        "txt" => { "path" => s["path"], "vid" => s["vid"], "pid" => s["pid"], "via" => "usb" }.compact }
    end
  end

  def usb_match?(m, s)
    desc = "#{s['manufacturer']} #{s['product']} #{s['id']}".downcase
    (m[:vid].nil? || m[:vid].to_s.casecmp?(s["vid"].to_s)) && (m[:pid].nil? || m[:pid].to_s.casecmp?(s["pid"].to_s)) &&
      (m[:description].nil? || File.fnmatch?(m[:description].downcase, desc))
  end
end
