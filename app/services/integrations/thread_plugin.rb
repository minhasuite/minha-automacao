module Integrations
  # Thread (ondaC1, C3; o `thread` + `otbr` do HA): um OpenThread Border
  # Router por integração (container `otbr`, perfil `thread` do compose, ou o
  # add-on do HA). A tela Gerenciar mostra a rede (estado, nome, canal, PAN),
  # forma uma rede nova, importa um dataset de outro app, marca a rede
  # preferida do local e manda as credenciais aos servidores Matter.
  # Não tem aparelhos próprios: os aparelhos Thread entram pelo Matter.
  class ThreadPlugin < Plugin
    describe key: "thread", title: "Thread (OpenThread Border Router)", icon: "share",
             description: "Rede Thread pelo OpenThread Border Router: estado, rede preferida e credenciais para os aparelhos Matter sobre Thread."
    texts "pt-BR" => { bad_url: "Endereço do OTBR deve começar com http:// (ex.: http://192.168.0.10:8081).", connected: "Border router conectado: %{state}.",
                       failed: "Não deu para falar com o OTBR: %{error}", formed: "Rede Thread %{name} criada e ligada.", imported: "Dataset importado e guardado.",
                       bad_dataset: "Dataset inválido: cole o TLV em hexadecimal (o \"dataset ativo\" do outro app).", preferred: "Esta é a rede Thread preferida do local.",
                       sent: "Credenciais Thread enviadas a %{n} servidor(es) Matter.", no_matter: "Nenhum servidor Matter neste local.", no_dataset: "O border router ainda não tem rede.",
                       unknown_action: "Ação desconhecida." },
          en: { title: "Thread (OpenThread Border Router)", description: "Thread network through the OpenThread Border Router: status, preferred network and credentials for Matter-over-Thread devices.",
                bad_url: "The OTBR address must start with http:// (e.g. http://192.168.0.10:8081).", connected: "Border router connected: %{state}.",
                failed: "Couldn't reach the OTBR: %{error}", formed: "Thread network %{name} created and enabled.", imported: "Dataset imported and saved.",
                bad_dataset: "Invalid dataset: paste the hexadecimal TLV (the other app's \"active dataset\").", preferred: "This is the site's preferred Thread network.",
                sent: "Thread credentials sent to %{n} Matter server(s).", no_matter: "No Matter server on this site.", no_dataset: "The border router has no network yet.",
                unknown_action: "Unknown action." },
          es: { title: "Thread (OpenThread Border Router)", description: "Red Thread mediante el OpenThread Border Router: estado, red preferida y credenciales para los aparatos Matter sobre Thread.",
                bad_url: "La dirección del OTBR debe empezar con http:// (ej.: http://192.168.0.10:8081).", connected: "Border router conectado: %{state}.",
                failed: "No se pudo comunicar con el OTBR: %{error}", formed: "Red Thread %{name} creada y activada.", imported: "Dataset importado y guardado.",
                bad_dataset: "Dataset no válido: pega el TLV en hexadecimal (el \"dataset activo\" de la otra app).", preferred: "Esta es la red Thread preferida del lugar.",
                sent: "Credenciales Thread enviadas a %{n} servidor(es) Matter.", no_matter: "Ningún servidor Matter en este lugar.", no_dataset: "El border router todavía no tiene red.",
                unknown_action: "Acción desconocida." }

    mdns "_meshcop._udp"

    def self.setup(site, form) = login(new_integration(site, name: form[:name].to_s.squish.presence || "Thread"), form)

    def self.login(integration, form)
      url = form[:url].to_s.strip.presence || integration.settings["url"]
      return outcome(:form, alert: text(:bad_url)) unless url.to_s.match?(%r{\Ahttps?://\S+\z})

      integration.settings = integration.settings.merge("url" => url, "account" => URI(url).host)
      integration.settings["preferred"] = true unless integration.site.integrations.where(driver: "thread").where.not(id: integration.id).exists?
      integration.save!
      store_dataset(integration)
      integration.ok!
      outcome(:panel, integration: integration, notice: text(:connected, state: Otbr.node(url)["State"] || "?"))
    rescue Otbr::Error => e
      integration.error!(e) if integration.persisted?
      outcome(:panel, integration: integration, alert: text(:failed, error: e.message))
    end

    def self.custom_sync? = true

    def self.sync!(integration)
      store_dataset(integration)
      integration.ok!
      { found: 0, fresh: 0, removed: 0 }
    rescue Otbr::Error => e
      integration.error!(e)
      raise Integrations::Error, e.message
    end

    def self.inventory(_integration) = []

    # Dataset ativo do OTBR → segredo da integração (é a chave da rede).
    def self.store_dataset(integration)
      hex = Otbr.dataset_hex(integration.settings["url"]) or return
      integration.merge_secrets!("dataset" => hex) if integration.secrets["dataset"] != hex
    end

    # Rede preferida do local (a que o Matter usa).
    def self.preferred(site) = site.integrations.where(driver: "thread").find { |i| i.settings["preferred"] } || site.integrations.find_by(driver: "thread")
    def self.preferred_dataset(site) = preferred(site)&.secrets&.dig("dataset")

    def self.panel? = true

    def self.panel_locals(integration, _params)
      node = Otbr.node(integration.settings["url"])
      hex = Otbr.dataset_hex(integration.settings["url"]) || integration.secrets["dataset"]
      { node: node, dataset: hex ? Otbr.parse(hex) : {}, preferred: integration.settings["preferred"] == true,
        matter: integration.site.integrations.where(driver: "matter").to_a }
    rescue Otbr::Error => e
      raise Integrations::Error, e.message
    end

    def self.panel_action(integration, action, params)
      url = integration.settings["url"]
      notice = case action
      when "form"
        name = params[:network_name].to_s.squish.presence || "MA-#{SecureRandom.hex(2).upcase}"
        Otbr.form!(url, name)
        store_dataset(integration)
        text(:formed, name: name)
      when "import"
        hex = params[:dataset].to_s.delete("^0-9a-fA-F").downcase
        raise Integrations::Error, text(:bad_dataset) unless Otbr.valid_hex?(hex)

        integration.merge_secrets!("dataset" => hex)
        text(:imported)
      when "prefer"
        integration.site.integrations.where(driver: "thread").find_each { |i| i.update!(settings: i.settings.merge("preferred" => i.id == integration.id)) }
        text(:preferred)
      when "send_matter" then send_matter(integration)
      else raise Integrations::Error, text(:unknown_action)
      end
      outcome(:panel, integration: integration, notice: notice)
    rescue Otbr::Error, Matter::Client::Error => e
      raise Integrations::Error, e.message
    end

    def self.send_matter(integration)
      hex = integration.secrets["dataset"] or raise Integrations::Error, text(:no_dataset)
      servers = integration.site.integrations.where(driver: "matter").to_a
      raise Integrations::Error, text(:no_matter) if servers.empty?

      servers.each { |m| Matter::Client.open(m.settings["url"]) { |c| c.set_thread_dataset(hex) } }
      text(:sent, n: servers.size)
    end
  end
end
