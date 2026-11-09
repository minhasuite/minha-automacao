module Integrations
  # Base dos aparelhos da rede de casa (Pacote 1: ESPHome, Shelly, TVs,
  # Chromecast, Broadlink…): uma integração por aparelho, como no HA. O
  # assistente pede endereço, porta e os segredos do plugin (`secrets`, vão
  # cifrados na integração); a varredura conecta e devolve uma entrada de
  # inventário (`probe`). Achar o IP fica com o `mdns` do plugin (só lista).
  #
  # Plugin novo da rede = subclasse com `describe`, `port`, `secrets` (se
  # tiver), `probe(integration)` → entrada (formato de `Integrations`) e a
  # partial do formulário (sem segredo nem campo próprio, nenhuma: vale a comum
  # `forms/lan` com a nota `integrations.forms.<key>.note`).
  class LanPlugin < Plugin
    texts "pt-BR" => { no_host: "Informe o IP ou o nome do aparelho na rede.", read_failed: "Não deu para ler o aparelho: %{error}" },
          en: { no_host: "Enter the device's IP or network name.", read_failed: "Couldn't read the device: %{error}" },
          es: { no_host: "Ingresa la IP o el nombre del aparato en la red.", read_failed: "No se pudo leer el aparato: %{error}" }
    # Erros de rede que viram "Não deu para ler o aparelho" (e não 500).
    NET_ERRORS = [ SystemCallError, IOError, SocketError, Timeout::Error, OpenSSL::SSL::SSLError, JSON::ParserError, EOFError ].freeze

    class << self
      def port(value = nil)
        @port = value if value
        @port
      end

      # Campos do formulário guardados cifrados (chave, senha, token).
      def secrets(*fields)
        @secrets = fields.map(&:to_s) if fields.any?
        @secrets || []
      end

      # integ: campos do formulário guardados às claras em settings (usuário, tópico).
      def plain(*fields)
        @plain = fields.map(&:to_s) if fields.any?
        @plain || []
      end

      def setup(site, form)
        host = form[:host].to_s.strip
        return outcome(:form, alert: text(:no_host)) if host.blank?

        login(new_integration(site, name: form[:name].to_s.squish.presence || "#{title} #{host}"), form)
      end

      def login(integration, form)
        s = integration.settings
        host = form[:host].to_s.strip.presence || s["host"]
        integration.settings = s.merge("host" => host, "port" => (form[:port].presence || s["port"] || port)&.to_i, "account" => host)
                                .merge(plain.to_h { |k| [ k, form[k].to_s.strip ] }.compact_blank).compact
        values = secrets.to_h { |k| [ k, form[k].to_s.strip ] }.compact_blank
        integration.credentials = integration.secrets.merge(values).to_json if values.any?
        integration.save!
        r = Integrations.sync!(integration)
        outcome(:found, integration: integration, notice: "#{r[:found]} aparelho(s) lido(s).")
      rescue Integrations::Error => e
        outcome(:found, integration: integration, alert: text(:read_failed, error: e.message))
      end

      # Achado na rede (primeira configuração): cria e varre na fila; TV que
      # pede pareamento não segura a tela. Chave/senha faltando = "Com erro",
      # e o Reconfigurar da integração resolve.
      def add_found(site, entry)
        host = entry["host"].to_s.strip.presence or return
        integration = new_integration(site, name: entry["name"].to_s.squish.presence || "#{title} #{host}")
        integration.settings = { "host" => host, "port" => (entry["port"].presence || port)&.to_i, "account" => host }.compact
        integration.save!
        Integrations.start_sync!(integration)
        integration
      end

      def inventory(integration) = [ probe(integration) ]
      def probe(_integration) = raise(NotImplementedError)

      # Os drivers leem os segredos da integração do aparelho.
      def device_secret(_integration, _entry) = nil

      def host_of(integration) = integration.settings["host"]
      def port_of(integration) = (integration.settings["port"].presence || port).to_i
    end
  end
end
