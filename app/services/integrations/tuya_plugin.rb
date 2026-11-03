module Integrations
  # Smart Life / Tuya Smart por QR code (como a integração `tuya` do HA):
  # aparelhos da conta, inclusive os Zigbee atrás do hub, com estado, comando
  # pela nuvem e tempo real pelo MQTT (Tuya::CloudListener). O que já está no
  # local pelo LocalTuya é o mesmo aparelho e continua com comando local.
  class TuyaPlugin < Plugin
    describe key: "tuya", title: "Tuya / Smart Life", icon: "light-bulb",
             description: "Aparelhos do app Smart Life, inclusive os Zigbee do hub. Entra pelo QR code, como no Home Assistant; o que também está na rede local continua local."
    texts "pt-BR" => { need_code: "Informe o código de usuário do app.", need_device: "O app não mandou o aparelho pareado (id e chave local)." },
          en: { title: "Tuya / Smart Life", description: "Devices from the Smart Life app, including Zigbee ones on the hub. Signs in with a QR code, just like Home Assistant; anything also on the local network stays local.", need_code: "Enter the app's user code.", need_device: "The app didn't send the paired device (id and local key)." },
          es: { title: "Tuya / Smart Life", description: "Aparatos de la app Smart Life, incluso los Zigbee del hub. Entra con código QR, como en Home Assistant; lo que también está en la red local sigue siendo local.", need_code: "Ingresa el código de usuario de la app.", need_device: "La app no envió el aparato emparejado (id y clave local)." }

    def self.setup(site, form)
      code = form[:user_code].to_s.strip
      return outcome(:form, alert: text(:need_code)) if code.blank?

      i = new_integration(site, name: "Smart Life", status: "pending", credentials: { "user_code" => code }.to_json)
      i.save!
      outcome(:connect, integration: i)
    end

    def self.login(integration, form)
      integration.merge_secrets!("user_code" => form[:user_code].to_s.strip) if form[:user_code].present?
      outcome(:connect, integration: integration)
    end

    def self.connect_locals(integration, _params)
      # QR = texto da Tuya; o SVG sai do rqrcode, sem texto de fora.
      token = Tuya::Cloud.qr_code(integration.secrets["user_code"])
      integration.merge_secrets!("qr" => token)
      { qr_svg: RQRCode::QRCode.new(Tuya::Cloud.qr_text(token)).as_svg(module_size: 5, standalone: true, use_path: true, viewbox: true).html_safe } # rubocop:disable Rails/OutputSafety -- SVG do rqrcode, sem texto de fora
    end

    def self.logged_in?(integration)
      s = integration.secrets
      info = s["qr"].presence && Tuya::Cloud.login_result(s["qr"], s["user_code"])
      return false unless info

      integration.merge_secrets!(info.except("username").merge("qr" => nil))
      integration.update!(settings: integration.settings.merge("account" => info["username"].presence || "Smart Life"))
      Integrations.start_sync!(integration)
    end

    # tuya: pareamento pelo app (SDK oficial da Tuya, sem o Smart Life). A
    # conta do SDK é uma por local: uid e senha derivados do segredo do
    # servidor (nada gravado), para o `loginOrRegisterWithUid` do app.
    def self.pairing_session(site, _user)
      digest = OpenSSL::HMAC.hexdigest("SHA256", Rails.application.secret_key_base, "tuya-sdk:#{site.id}")
      { "uid" => "ma#{digest[0, 20]}", "password" => digest[20, 32], "country_code" => "55", "home_name" => site.name }
    end

    # Tipo do dp no schema do SDK → tipo da API da nuvem (Tuya::Cloud.points).
    SDK_TYPES = { "bool" => "Boolean", "value" => "Integer", "enum" => "Enum", "string" => "String", "bitmap" => "Bitmap", "raw" => "Raw" }.freeze

    # Aparelho que o app pareou ({device_id, local_key, name, schema…}) →
    # aparelho `tuya_local` (comando local pela local_key), com os pontos da
    # mesma tradução da nuvem. Pareado de novo = atualiza chave, nome e IP.
    def self.pair(site, form)
      id = form[:device_id].to_s.strip
      key = form[:local_key].to_s.strip
      raise Integrations::Error, text(:need_device) if id.blank? || key.blank?

      schema = Array(form[:schema]).map { |s| s.to_h.stringify_keys }
      relations = schema.map do |s|
        desc = s["property"].is_a?(String) ? s["property"] : s["property"].to_h.to_json
        { "statusCode" => s["code"].to_s, "dpId" => s["id"].to_s, "valueType" => SDK_TYPES[s["type"].to_s], "valueDesc" => desc }
      end
      writable = schema.select { |s| s["mode"].to_s.include?("w") }.map { |s| s["code"].to_s }
      name = form[:name].to_s.squish.presence || id
      address = { "host" => lan_ip(form[:ip]), "version" => form[:version].presence, "via" => form[:parent_id].presence }.compact

      ActiveRecord::Base.transaction do
        device = site.devices.find_by(driver: Tuya::Cloud::DRIVERS, external_id: id) || site.devices.new(driver: "tuya_local", external_id: id)
        device.assign_attributes(name: name, credential: key, manufacturer: "Tuya", address: device.address.to_h.merge(address), removed_at: nil, discovered_at: device.discovered_at || Time.current)
        device.model = form[:product_name].presence || device.model
        device.area = Integrations.area_for(site, form[:area_id].presence || (form[:area_name].present? ? "new:#{form[:area_name]}" : nil)) || device.area
        device.save!
        Integrations.add_points(device, "points" => Tuya::Cloud.points(name, relations, writable))
        device
      end
    end

    # O SDK devolve o IP de onde o aparelho saiu para a nuvem (público); só o da LAN serve para o comando local.
    def self.lan_ip(ip)
      ip.presence && IPAddr.new(ip.to_s).private? ? ip.to_s : nil
    rescue IPAddr::InvalidAddressError
      nil
    end

    def self.inventory(integration) = Tuya::Cloud.new(integration).inventory

    # Lote 9: vídeo da câmera pela nuvem, pedido na hora (ponto `stream` sob demanda).
    def self.stream_url(point) = Tuya::Cloud.new(point.device.integration).stream_url(point.device.external_id)

    # Aparelhos da conta já no local (nuvem ou LocalTuya ligado a ela).
    def self.devices(integration) = integration.devices.where(driver: Tuya::Cloud::DRIVERS, removed_at: nil, disabled: false)

    # Estado da última varredura nos aparelhos; o LocalTuya ligado ganha o
    # código de cada dp (comando sem IP e tempo real pela nuvem).
    def self.refresh(integration)
      by_id = integration.found.index_by { |e| e["id"] }
      devices(integration).includes(:points).find_each do |device|
        e = by_id[device.external_id] or next
        fill_codes(device, e)
        apply(device, e)
      rescue StandardError => ex
        Rails.logger.warn("[tuya] estado de #{device.name}: #{ex.message}")
      end
    end

    # {online, state} da nuvem → aparelho (fora do ar = pontos indisponíveis).
    def self.apply(device, info)
      return Drivers::TuyaLocal.unavailable!(device) if info["online"] == false

      Drivers::TuyaCloud.report(device, info["state"].to_h)
    end

    def self.fill_codes(device, e)
      codes = Array(e["points"]).to_h { |p| [ p.dig("address", "dps").to_s, p.dig("address", "code") ] }
      device.points.each do |p|
        code = codes[p.address["dps"].to_s]
        p.update_columns(address: p.address.merge("code" => code)) if code && p.address["code"] != code
      end
    end
  end
end
