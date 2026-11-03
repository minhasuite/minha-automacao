module Integrations
  # Bluetooth do próprio servidor (ondaC1, C2; o `bluetooth` do HA): o
  # serviço `ble-scanner` do compose (perfil `bluetooth`, desligado) ouve o
  # adaptador do Linux e manda os anúncios (Ble::Hub). A integração guarda as
  # chaves (BTHome cifrado, bindkey Xiaomi); a tela Gerenciar mostra o
  # adaptador, o que está sendo ouvido e gera a chave do serviço.
  class BluetoothPlugin < Plugin
    describe key: "bluetooth", title: "Bluetooth (adaptador do servidor)", icon: "status-online",
             description: "Sensores Bluetooth ouvidos pelo adaptador do próprio servidor (BTHome, Xiaomi, pvvx/ATC, Govee, iBeacon, Oral-B), em tempo real e sem placa extra."
    texts "pt-BR" => { added: "Bluetooth pronto. Ligue o serviço ble-scanner com a chave da tela Gerenciar.", key_generated: "Chave do serviço (aparece só agora; coloque em BLE_SCANNER_KEY no .env): %{key}",
                       adapter: "Adaptador", last_batch: "Último lote", heard: "Aparelhos ouvidos", understood: "Entendidos", never: "Nunca",
                       service_key: "Gerar chave do serviço", unknown_action: "Ação desconhecida." },
          en: { title: "Bluetooth (server adapter)", description: "Bluetooth sensors heard by the server's own adapter (BTHome, Xiaomi, pvvx/ATC, Govee, iBeacon, Oral-B), in real time and without an extra board.",
                added: "Bluetooth ready. Start the ble-scanner service with the key from the Manage screen.", key_generated: "Service key (shown only now; put it in BLE_SCANNER_KEY in .env): %{key}",
                adapter: "Adapter", last_batch: "Last batch", heard: "Devices heard", understood: "Understood", never: "Never", service_key: "Generate service key", unknown_action: "Unknown action." },
          es: { title: "Bluetooth (adaptador del servidor)", description: "Sensores Bluetooth escuchados por el adaptador del propio servidor (BTHome, Xiaomi, pvvx/ATC, Govee, iBeacon, Oral-B), en tiempo real y sin placa extra.",
                added: "Bluetooth listo. Inicia el servicio ble-scanner con la clave de la pantalla Administrar.", key_generated: "Clave del servicio (se muestra solo ahora; ponla en BLE_SCANNER_KEY del .env): %{key}",
                adapter: "Adaptador", last_batch: "Último lote", heard: "Aparatos escuchados", understood: "Entendidos", never: "Nunca", service_key: "Generar clave del servicio", unknown_action: "Acción desconocida." }

    def self.setup(site, form)
      i = new_integration(site, name: form[:name].to_s.squish.presence || title)
      login(i, form)
      outcome(:panel, integration: i, notice: text(:added))
    end

    def self.login(integration, form)
      integration.settings = integration.settings.merge("account" => "hci0")
      integration.merge_secrets!("bindkeys" => form[:bindkeys].to_s.strip) if form[:bindkeys].present?
      integration.save!
      outcome(:panel, integration: integration)
    end

    def self.inventory(integration) = Ble::Hub.entries(integration)

    # Depois da adoção: o último anúncio ouvido já vira valor.
    def self.refresh(integration)
      seen = Ble::Hub.seen(integration)
      integration.devices.where(driver: driver, removed_at: nil, disabled: false).includes(:points).find_each { |d| (s = seen[d.external_id]) && Ble.apply(d, s["values"].to_h) }
    end
    def self.tick(_now) = Integration.where(driver: "bluetooth").find_each { |i| ActsAsTenant.with_tenant(i.tenant) { Ble::Hub.expire_presence!(i) } }

    def self.panel? = true

    def self.panel_locals(integration, _params)
      hub = Ble::Hub.read(integration)
      seen = hub["seen"].to_h
      { stats: [ [ text(:adapter), hub.dig("adapter", "name").presence || "—" ], [ text(:last_batch), hub["at"] ? I18n.l(Time.zone.parse(hub["at"]), format: :short) : text(:never) ],
                 [ text(:heard), seen.size ], [ text(:understood), seen.count { |_, s| s["values"].present? } ] ],
        rows: seen.sort_by { |_, s| s["at"].to_s }.reverse.first(30).map { |id, s| [ "#{s['model']} · #{id}", Ble.summary(s["values"]) ] },
        actions: [ [ "service_key", text(:service_key) ] ] }
    end

    def self.panel_action(integration, action, _params)
      raise Integrations::Error, text(:unknown_action) unless action == "service_key"

      _, key = ServiceApiKey.issue(Current.user, name: "#{title} (#{integration.site.name})", scopes: %w[write], site_ids: [ integration.site_id ])
      outcome(:panel, integration: integration, notice: text(:key_generated, key: key))
    end
  end
end
