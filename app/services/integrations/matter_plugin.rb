module Integrations
  # Matter (Pacote 1): um servidor python-matter-server (o mesmo do HA; serviço
  # opcional `matter-server` do compose) por integração. A varredura lista os
  # nós; cada nó adotado vira aparelho `matter` com os pontos do mapa
  # `config/device_maps/matter.yml`. "Comissionar aparelho" (Reconfigurar)
  # manda o código de pareamento ao servidor e varre de novo.
  class MatterPlugin < Plugin
    describe key: "matter", title: "Matter", icon: "chip",
             description: "Aparelhos Matter (Wi-Fi e Thread) pelo Matter Server, o mesmo do Home Assistant. Lista os aparelhos do servidor e comissiona novos pelo código de pareamento."

    CODE = /\A(MT:[A-Z0-9.\-]{10,}|\d{11}|\d{21})\z/

    def self.setup(site, form)
      login(new_integration(site, name: form[:name].to_s.squish.presence || "Matter"), form)
    end

    def self.login(integration, form)
      url = form[:url].to_s.strip.presence || integration.settings["url"] || ENV["MATTER_URL"].presence || Matter::Client::DEFAULT_URL
      return outcome(:form, alert: "Endereço do servidor deve começar com ws:// ou wss://.") unless url.match?(%r{\Awss?://\S+\z})

      integration.settings = integration.settings.merge("url" => url, "account" => URI(url).host)
      integration.save!
      code = form[:code].to_s.delete(" -").upcase.presence
      notice = commission(integration, code) if code
      r = Integrations.sync!(integration)
      outcome(:found, integration: integration, notice: notice || "#{r[:found]} aparelho(s) no servidor Matter.")
    rescue Integrations::Error, Matter::Client::Error => e
      outcome(:found, integration: integration, alert: "Não deu para falar com o servidor Matter: #{e.message}")
    end

    def self.commission(integration, code)
      raise Integrations::Error, "Código de pareamento inválido (MT:… do QR ou os 11 dígitos)." unless code.match?(CODE)

      node = Matter::Client.open(integration.settings["url"]) { |c| c.commission(code) }
      "Aparelho comissionado (nó #{node.is_a?(Hash) ? node['node_id'] : node}). Marque-o abaixo para adicionar."
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
