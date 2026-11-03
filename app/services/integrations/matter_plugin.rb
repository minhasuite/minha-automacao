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

    texts "pt-BR" => { shared: "Janela de pareamento aberta por 3 min: leia o QR no outro app.", interviewed: "Reentrevistando o nó %{node}.", removed: "Nó %{node} removido do servidor.",
                       bad_ssid: "Informe o nome da rede Wi-Fi.", wifi_saved: "Wi-Fi guardado no servidor Matter.", no_thread: "Nenhuma rede Thread preferida no local (adicione a integração Thread).",
                       thread_saved: "Credenciais Thread mandadas ao servidor Matter.", unknown_action: "Ação desconhecida." },
          en: { shared: "Pairing window open for 3 min: scan the QR in the other app.", interviewed: "Re-interviewing node %{node}.", removed: "Node %{node} removed from the server.",
                bad_ssid: "Enter the Wi-Fi network name.", wifi_saved: "Wi-Fi saved on the Matter server.", no_thread: "No preferred Thread network on this site (add the Thread integration).",
                thread_saved: "Thread credentials sent to the Matter server.", unknown_action: "Unknown action." },
          es: { shared: "Ventana de vinculación abierta por 3 min: lee el QR en la otra app.", interviewed: "Reentrevistando el nodo %{node}.", removed: "Nodo %{node} quitado del servidor.",
                bad_ssid: "Escribe el nombre de la red Wi-Fi.", wifi_saved: "Wi-Fi guardado en el servidor Matter.", no_thread: "Ninguna red Thread preferida en el lugar (agrega la integración Thread).",
                thread_saved: "Credenciales Thread enviadas al servidor Matter.", unknown_action: "Acción desconocida." }

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

    # ondaC1 (C3): tela Gerenciar (servidor, comissionar pela rede ou pelo
    # Bluetooth do servidor, Wi-Fi e Thread para comissionar, compartilhar com
    # outro app = multi-admin, reentrevistar, remover). Firmware pelo ar em
    # Firmware::Providers::Matter.
    SHARE_TTL = 3.minutes

    def self.panel? = true
    def self.share_key(integration) = "matter:share:#{integration.id}"

    def self.panel_locals(integration, _params)
      Matter::Client.open(integration.settings["url"]) do |c|
        { info: c.server_info.to_h, nodes: Array(c.nodes), share: Rails.cache.read(share_key(integration)),
          thread_dataset: ThreadPlugin.preferred_dataset(integration.site) }
      end
    rescue Matter::Client::Error => e
      raise Integrations::Error, e.message
    end

    def self.panel_action(integration, action, params)
      notice = Matter::Client.open(integration.settings["url"]) { |c| run_action(c, integration, action, params) }
      outcome(:panel, integration: integration, notice: notice)
    rescue Matter::Client::Error => e
      raise Integrations::Error, text(:failed, error: e.message)
    end

    def self.run_action(c, integration, action, params)
      node = params[:node].to_i
      case action
      when "commission"
        code = params[:code].to_s.delete(" -").upcase
        raise Integrations::Error, text(:bad_code) unless code.match?(CODE)

        r = c.commission(code, network_only: params[:mode] != "ble")
        Integrations.start_sync!(integration)
        text(:commissioned, node: r.is_a?(Hash) ? r["node_id"] : r)
      when "share"
        r = c.open_commissioning_window(node).to_h
        n = Array(c.nodes).find { |x| x["node_id"] == node }
        Rails.cache.write(share_key(integration), { "node" => node, "name" => n ? Matter::Map.entry(n)["name"] : node.to_s, "manual" => r["setup_manual_code"],
                                                    "qr" => r["setup_qr_code"], "until" => SHARE_TTL.from_now.iso8601 }, expires_in: SHARE_TTL)
        text(:shared)
      when "interview" then c.interview(node) && text(:interviewed, node: node)
      when "remove"
        c.remove_node(node)
        Integrations.start_sync!(integration)
        text(:removed, node: node)
      when "wifi"
        raise Integrations::Error, text(:bad_ssid) if params[:ssid].to_s.strip.empty?

        c.set_wifi_credentials(params[:ssid].to_s.strip, params[:password].to_s) && text(:wifi_saved)
      when "thread"
        hex = ThreadPlugin.preferred_dataset(integration.site) or raise Integrations::Error, text(:no_thread)
        c.set_thread_dataset(hex) && text(:thread_saved)
      else raise Integrations::Error, text(:unknown_action)
      end
    end
  end
end
