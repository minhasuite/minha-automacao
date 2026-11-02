module Integrations
  # Matter (Pacote 1): um servidor python-matter-server (o mesmo do HA; serviço
  # opcional `matter-server` do compose) por integração. A varredura lista os
  # nós; cada nó adotado vira aparelho `matter` com os pontos do mapa
  # `config/device_maps/matter.yml`. "Comissionar aparelho" (Reconfigurar)
  # manda o código de pareamento ao servidor e varre de novo.
  class MatterPlugin < Plugin
    describe key: "matter", title: "Matter", icon: "chip",
             description: "Aparelhos Matter (Wi-Fi e Thread) pelo Matter Server, o mesmo do Home Assistant. Lista os aparelhos do servidor e comissiona novos pelo código de pareamento."
    texts "pt-BR" => { bad_url: "Endereço do servidor deve começar com ws:// ou wss://.", found: "%{n} aparelho(s) no servidor Matter.", failed: "Não deu para falar com o servidor Matter: %{error}", bad_code: "Código de pareamento inválido (MT:… do QR ou os 11 dígitos).", commissioned: "Aparelho comissionado (nó %{node}). Marque-o abaixo para adicionar." },
          en: { title: "Matter", description: "Matter devices (Wi-Fi and Thread) through Matter Server, the same one Home Assistant uses. Lists the server's devices and commissions new ones with the pairing code.", bad_url: "The server address must start with ws:// or wss://.", found: "%{n} device(s) on the Matter server.", failed: "Couldn't reach the Matter server: %{error}", bad_code: "Invalid pairing code (MT:… from the QR or the 11 digits).", commissioned: "Device commissioned (node %{node}). Check it below to add it." },
          es: { title: "Matter", description: "Aparatos Matter (Wi-Fi y Thread) mediante Matter Server, el mismo de Home Assistant. Lista los aparatos del servidor y comisiona nuevos con el código de vinculación.", bad_url: "La dirección del servidor debe empezar con ws:// o wss://.", found: "%{n} aparato(s) en el servidor Matter.", failed: "No se pudo comunicar con el servidor Matter: %{error}", bad_code: "Código de vinculación no válido (MT:… del QR o los 11 dígitos).", commissioned: "Aparato comisionado (nodo %{node}). Márcalo abajo para agregarlo." }

    CODE = /\A(MT:[A-Z0-9.\-]{10,}|\d{11}|\d{21})\z/

    def self.setup(site, form)
      login(new_integration(site, name: form[:name].to_s.squish.presence || "Matter"), form)
    end

    def self.login(integration, form)
      url = form[:url].to_s.strip.presence || integration.settings["url"] || ENV["MATTER_URL"].presence || Matter::Client::DEFAULT_URL
      return outcome(:form, alert: text(:bad_url)) unless url.match?(%r{\Awss?://\S+\z})

      integration.settings = integration.settings.merge("url" => url, "account" => URI(url).host)
      integration.save!
      code = form[:code].to_s.delete(" -").upcase.presence
      notice = commission(integration, code) if code
      r = Integrations.sync!(integration)
      outcome(:found, integration: integration, notice: notice || text(:found, n: r[:found]))
    rescue Integrations::Error, Matter::Client::Error => e
      outcome(:found, integration: integration, alert: text(:failed, error: e.message))
    end

    def self.commission(integration, code)
      raise Integrations::Error, text(:bad_code) unless code.match?(CODE)

      node = Matter::Client.open(integration.settings["url"]) { |c| c.commission(code) }
      text(:commissioned, node: node.is_a?(Hash) ? node["node_id"] : node)
    end

    def self.inventory(integration)
      Matter::Client.open(integration.settings["url"]) { |c| Array(c.nodes) }.map { |n| Matter::Map.entry(n) }
    rescue Matter::Client::Error => e
      raise Integrations::Error, e.message
    end

    # Estado de agora nos aparelhos adotados (o ouvinte segue daí).
    def self.refresh(integration)
      devices = integration.devices.where(driver: driver, removed_at: nil).includes(:points).to_a
      return if devices.empty?

      nodes = Matter::Client.open(integration.settings["url"]) { |c| Array(c.nodes) }.index_by { |n| n["node_id"].to_s }
      devices.each { |d| (n = nodes[d.external_id]) && Matter::Map.apply(d, n) }
    rescue Matter::Client::Error => e
      Rails.logger.warn("[matter] estado: #{e.message}")
    end
  end
end
