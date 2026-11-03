module Integrations
  # HomeKit (aparelhos) (ondaC1, C5; o homekit_controller do HA): o MA vira
  # controlador de um acessório HomeKit da rede (Wi-Fi/Ethernet, `_hap._tcp`),
  # sem Apple no meio: pareia pelo código de 8 dígitos (Hap::Client), lê o
  # banco de acessórios (uma ponte HomeKit traz vários) e cada acessório
  # adotado vira aparelho `homekit` com os pontos do mapa homekit.yml. O
  # pareamento (chaves) fica cifrado nos segredos da integração. O acessório
  # precisa estar livre: tire-o do app Casa antes (um controlador por vez,
  # como no HA).
  class HomekitPlugin < Plugin
    describe key: "homekit_controller", title: "HomeKit (aparelhos)", icon: "home", driver: "homekit",
             description: "Aparelhos HomeKit da rede (Wi-Fi/Ethernet): o MA pareia pelo código de 8 dígitos e comanda direto, sem iPhone nem nuvem."
    texts "pt-BR" => { bad_host: "Informe o endereço do acessório (o IP que aparece em Procurar na rede).", bad_code: "O código HomeKit tem 8 dígitos (ex.: 031-45-154).",
                       paired: "Acessório pareado. Marque abaixo o que adicionar.", failed: "Não deu para parear: %{error}" },
          en: { title: "HomeKit (devices)", description: "HomeKit devices on the network (Wi-Fi/Ethernet): the MA pairs with the 8-digit code and controls them directly, no iPhone or cloud.",
                bad_host: "Enter the accessory address (the IP shown in Search the network).", bad_code: "The HomeKit code has 8 digits (e.g. 031-45-154).",
                paired: "Accessory paired. Check below what to add.", failed: "Couldn't pair: %{error}" },
          es: { title: "HomeKit (aparatos)", description: "Aparatos HomeKit de la red (Wi-Fi/Ethernet): el MA vincula con el código de 8 dígitos y controla directo, sin iPhone ni nube.",
                bad_host: "Escribe la dirección del accesorio (la IP de Buscar en la red).", bad_code: "El código HomeKit tiene 8 dígitos (ej.: 031-45-154).",
                paired: "Accesorio vinculado. Marca abajo qué agregar.", failed: "No se pudo vincular: %{error}" }

    mdns "_hap._tcp"
    PORT = 80

    def self.setup(site, form) = login(new_integration(site, name: form[:name].to_s.squish.presence || "HomeKit"), form)

    def self.login(integration, form)
      host = form[:host].to_s.strip.presence || integration.settings["host"]
      port = (form[:port].presence || integration.settings["port"] || PORT).to_i
      return outcome(:form, alert: text(:bad_host)) unless host.to_s.match?(/\A[\w.:-]+\z/)

      code = form[:code].to_s.delete("^0-9")
      return outcome(:form, alert: text(:bad_code)) if code.present? ? code.size != 8 : integration.secrets["pairing"].blank?

      integration.settings = integration.settings.merge("host" => host, "port" => port, "account" => host)
      integration.save!
      if code.present?
        client = Hap::Client.new(host, port)
        pairing = begin
          client.pair_setup!(code)
        ensure
          client.close
        end
        integration.merge_secrets!("pairing" => pairing.to_json)
      end
      Integrations.sync!(integration)
      outcome(:found, integration: integration, notice: text(:paired))
    rescue Hap::Error, *LanPlugin::NET_ERRORS => e
      outcome(:found, integration: integration, alert: text(:failed, error: e.message))
    end

    def self.pairing(integration) = JSON.parse(integration.secrets["pairing"].to_s.presence || "{}")
    def self.session(integration, &) = Hap::Client.open(integration.settings["host"], integration.settings["port"], pairing(integration), &)

    def self.inventory(integration)
      acc_id = pairing(integration)["accessory_id"]
      session(integration, &:accessories).map { |a| Hap::Map.entry(acc_id, a) }
    rescue Hap::Error, *LanPlugin::NET_ERRORS => e
      raise Integrations::Error, e.message
    end

    def self.refresh(integration)
      devices = integration.devices.where(driver: driver, removed_at: nil, disabled: false).includes(:points).to_a
      Drivers::Homekit.read(integration, devices) if devices.any?
    rescue Integrations::Error => e
      Rails.logger.warn("[homekit] estado: #{e.message}")
    end
  end
end
