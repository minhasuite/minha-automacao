module Integrations
  # Z-Wave JS (integ2): um zwave-js-server (add-on Z-Wave JS, Z-Wave JS UI
  # ou o container `zwave-js-server`) por integração, pelo WebSocket. A
  # varredura lista os nós; cada nó adotado vira aparelho `zwave_js` com os
  # pontos do mapa `config/device_maps/zwave.yml`.
  class ZwaveJsPlugin < Plugin
    describe key: "zwave_js", title: "Z-Wave JS", icon: "chip",
             description: "Aparelhos Z-Wave pelo servidor Z-Wave JS (o mesmo do Home Assistant): relés, dimmers, sensores, medidores e termostatos."

    def self.setup(site, form) = login(new_integration(site, name: form[:name].to_s.squish.presence || "Z-Wave JS"), form)

    def self.login(integration, form)
      url = form[:url].to_s.strip.presence || integration.settings["url"]
      return outcome(:form, alert: "Endereço do servidor deve começar com ws:// ou wss:// (ex.: ws://192.168.0.10:3000).") unless url.to_s.match?(%r{\Awss?://\S+\z})

      integration.settings = integration.settings.merge("url" => url, "account" => URI(url).host)
      integration.save!
      r = Integrations.sync!(integration)
      outcome(:found, integration: integration, notice: "#{r[:found]} nó(s) no servidor Z-Wave JS.")
    rescue Integrations::Error => e
      outcome(:found, integration: integration, alert: "Não deu para falar com o Z-Wave JS: #{e.message}")
    end

    def self.inventory(integration)
      state = ZwaveJs::Client.open(integration.settings["url"], &:state)
      home = state.dig("controller", "homeId")
      Array(state["nodes"]).reject { |n| n["isControllerNode"] }.map { |n| ZwaveJs.entry(home, n) }
    rescue ZwaveJs::Error => e
      raise Integrations::Error, e.message
    end

    # Estado logo depois da adoção (uma conexão para todos os nós).
    def self.refresh(integration)
      devices = integration.devices.where(driver: driver, removed_at: nil, disabled: false).includes(:points).to_a
      return if devices.empty?

      nodes = ZwaveJs::Client.open(integration.settings["url"], &:state)["nodes"].to_a.index_by { |n| n["nodeId"].to_s }
      devices.each { |d| (n = nodes[d.address["node"].to_s]) && ZwaveJs.apply(d, n) }
    rescue ZwaveJs::Error => e
      Rails.logger.warn("[zwave_js] estado: #{e.message}")
    end
  end
end
