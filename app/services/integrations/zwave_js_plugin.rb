module Integrations
  # Z-Wave JS (integ2): um zwave-js-server (add-on Z-Wave JS, Z-Wave JS UI
  # ou o container `zwave-js-server`) por integração, pelo WebSocket. A
  # varredura lista os nós; cada nó adotado vira aparelho `zwave_js` com os
  # pontos do mapa `config/device_maps/zwave.yml`.
  # ondaC1 (C1): tela "Gerenciar" com a rede (controlador, nós, segurança,
  # mapa pelos vizinhos), inclusão segura (S2 com o PIN do DSK, SmartStart
  # pelo QR), exclusão, refazer rotas, remover nó com falha e reentrevistar.
  # A inclusão corre no ouvinte (ZwaveJs::Listener) pelo ZwaveJs::Inclusion.
  class ZwaveJsPlugin < Plugin
    describe key: "zwave_js", title: "Z-Wave JS", icon: "chip",
             description: "Aparelhos Z-Wave pelo servidor Z-Wave JS (o mesmo do Home Assistant): relés, dimmers, sensores, medidores e termostatos."
    texts "pt-BR" => { bad_url: "Endereço do servidor deve começar com ws:// ou wss:// (ex.: ws://192.168.0.10:3000).", found: "%{n} nó(s) no servidor Z-Wave JS.", read_failed: "Não deu para falar com o Z-Wave JS: %{error}" },
          en: { title: "Z-Wave JS", description: "Z-Wave devices through the Z-Wave JS server (the same one Home Assistant uses): relays, dimmers, sensors, meters and thermostats.", bad_url: "The server address must start with ws:// or wss:// (e.g. ws://192.168.0.10:3000).", found: "%{n} node(s) found on the Z-Wave JS server.", read_failed: "Couldn't reach Z-Wave JS: %{error}" },
          es: { title: "Z-Wave JS", description: "Aparatos Z-Wave mediante el servidor Z-Wave JS (el mismo de Home Assistant): relés, dimmers, sensores, medidores y termostatos.", bad_url: "La dirección del servidor debe empezar con ws:// o wss:// (ej.: ws://192.168.0.10:3000).", found: "%{n} nodo(s) en el servidor Z-Wave JS.", read_failed: "No se pudo conectar con Z-Wave JS: %{error}" }

    # ondaC1: mensagens da tela "Gerenciar".
    texts "pt-BR" => { inclusion_started: "Inclusão ligada por 60 s: coloque o aparelho em modo de pareamento (normalmente 3 toques no botão).",
                       exclusion_started: "Exclusão ligada por 60 s: aperte o botão de pareamento do aparelho que vai sair da rede.",
                       stopping: "Parando…", granted: "Segurança concedida. Agora confira o código do aparelho.", bad_pin: "O PIN tem 5 dígitos (os primeiros do código DSK na etiqueta).",
                       pin_sent: "PIN enviado. Aguarde a entrevista do aparelho.", bad_qr: "Esse não é um QR Z-Wave SmartStart (começa com 90 e só tem números).",
                       provisioned: "Aparelho na lista SmartStart: ligue-o na tomada ou coloque a pilha e ele entra sozinho, com S2.",
                       unprovisioned: "Tirado da lista SmartStart.", rebuilding: "Refazendo as rotas da rede (pode levar alguns minutos).",
                       removed_failed: "Nó %{node} removido da rede.", reinterviewing: "Reentrevistando o nó %{node}.", unknown_action: "Ação desconhecida." },
          en: { inclusion_started: "Inclusion on for 60 s: put the device in pairing mode (usually 3 presses of its button).",
                exclusion_started: "Exclusion on for 60 s: press the pairing button of the device that will leave the network.",
                stopping: "Stopping…", granted: "Security granted. Now check the device code.", bad_pin: "The PIN has 5 digits (the first ones of the DSK on the label).",
                pin_sent: "PIN sent. Wait for the device interview.", bad_qr: "That isn't a Z-Wave SmartStart QR (it starts with 90 and has only digits).",
                provisioned: "Device on the SmartStart list: power it up or insert the battery and it joins by itself, with S2.",
                unprovisioned: "Removed from the SmartStart list.", rebuilding: "Rebuilding the network routes (it can take a few minutes).",
                removed_failed: "Node %{node} removed from the network.", reinterviewing: "Re-interviewing node %{node}.", unknown_action: "Unknown action." },
          es: { inclusion_started: "Inclusión activa por 60 s: pon el aparato en modo de vinculación (normalmente 3 toques en el botón).",
                exclusion_started: "Exclusión activa por 60 s: pulsa el botón de vinculación del aparato que saldrá de la red.",
                stopping: "Deteniendo…", granted: "Seguridad concedida. Ahora confirma el código del aparato.", bad_pin: "El PIN tiene 5 dígitos (los primeros del código DSK de la etiqueta).",
                pin_sent: "PIN enviado. Espera la entrevista del aparato.", bad_qr: "Ese no es un QR Z-Wave SmartStart (empieza con 90 y solo tiene números).",
                provisioned: "Aparato en la lista SmartStart: enchúfalo o pon la pila y entra solo, con S2.",
                unprovisioned: "Quitado de la lista SmartStart.", rebuilding: "Rehaciendo las rutas de la red (puede tardar unos minutos).",
                removed_failed: "Nodo %{node} quitado de la red.", reinterviewing: "Reentrevistando el nodo %{node}.", unknown_action: "Acción desconocida." }

    # Bastões Z-Wave comuns (os mesmos do manifesto do HA): Aeotec, Zooz/Silabs 700/800, Nortek.
    usb({ vid: "0658", pid: "0200" }, { vid: "10C4", pid: "EA60", description: "*700*" }, { vid: "10C4", pid: "EA60", description: "*800*" },
        { vid: "10C4", pid: "8A2A", description: "*z-wave*" }, { vid: "1A86", pid: "55D4", description: "*800*" })

    def self.setup(site, form) = login(new_integration(site, name: form[:name].to_s.squish.presence || "Z-Wave JS"), form)

    def self.login(integration, form)
      url = form[:url].to_s.strip.presence || integration.settings["url"]
      return outcome(:form, alert: text(:bad_url)) unless url.to_s.match?(%r{\Awss?://\S+\z})

      integration.settings = integration.settings.merge("url" => url, "account" => URI(url).host)
      integration.save!
      r = Integrations.sync!(integration)
      outcome(:found, integration: integration, notice: text(:found, n: r[:found]))
    rescue Integrations::Error => e
      outcome(:found, integration: integration, alert: text(:read_failed, error: e.message))
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

    MAX_MAP = 60

    def self.panel? = true
    def self.panel_refresh(integration) = (2000 if ZwaveJs::Inclusion.active?(integration.id))

    def self.panel_locals(integration, _params)
      ZwaveJs::Client.open(integration.settings["url"]) do |c|
        state = c.state
        nodes = Array(state["nodes"])
        neighbors = nodes.first(MAX_MAP).to_h { |n| [ n["nodeId"], (c.neighbors(n["nodeId"]) rescue []) ] } # rubocop:disable Style/RescueModifier
        { controller: state["controller"].to_h, server: c.version.to_h, nodes: nodes, map: ZwaveJs.network_map(nodes.first(MAX_MAP), neighbors),
          provisioning: (c.provisioning_entries rescue []), inclusion: ZwaveJs::Inclusion.get(integration.id) } # rubocop:disable Style/RescueModifier
      end
    rescue ZwaveJs::Error => e
      raise Integrations::Error, e.message
    end

    PIN = /\A\d{5}\z/
    QR = /\A90\d{50,}\z/

    def self.panel_action(integration, action, params)
      id = integration.id
      incl = ZwaveJs::Inclusion
      notice = case action
      when "include"
        incl.set(id, state: "requested", mode: "include", strategy: ZwaveJs::STRATEGIES.key?(params[:strategy]) ? params[:strategy] : "default")
        text(:inclusion_started)
      when "exclude"
        incl.set(id, state: "requested", mode: "exclude")
        text(:exclusion_started)
      when "stop" then incl.update(id, state: "stop") && text(:stopping)
      when "grant"
        asked = Array(incl.get(id)["requested"]).map(&:to_i)
        incl.update(id, state: "granted", grant: Array(params[:classes]).map(&:to_i) & asked) && text(:granted)
      when "pin"
        raise Integrations::Error, text(:bad_pin) unless params[:pin].to_s.match?(PIN)

        incl.update(id, state: "pin", pin: params[:pin].to_s) && text(:pin_sent)
      when "dismiss" then incl.clear(id) && nil
      else server_action(integration, action, params)
      end
      outcome(:panel, integration: integration, notice: notice)
    rescue ZwaveJs::Error => e
      raise Integrations::Error, e.message
    end

    # Ações de uma chamada só (não precisam do ouvinte).
    def self.server_action(integration, action, params)
      node = params[:node].to_i
      ZwaveJs::Client.open(integration.settings["url"]) do |c|
        case action
        when "smart_start"
          qr = params[:qr].to_s.delete("^0-9")
          raise Integrations::Error, text(:bad_qr) unless qr.match?(QR)

          c.provision(qr) && text(:provisioned)
        when "unprovision" then c.unprovision(params[:dsk].to_s) && text(:unprovisioned)
        when "rebuild_routes" then c.rebuild_routes && text(:rebuilding)
        when "remove_failed" then c.remove_failed(node) && Integrations.start_sync!(integration) && text(:removed_failed, node: node)
        when "reinterview" then c.reinterview(node) && text(:reinterviewing, node: node)
        else raise Integrations::Error, text(:unknown_action)
        end
      end
    end
  end
end
