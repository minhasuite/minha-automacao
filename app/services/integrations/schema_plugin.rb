module Integrations
  # catalogo (grupo 9): base das integrações do catálogo. O plugin declara os
  # campos (`field`) e o formulário sai deles, na web e no app (partial
  # genérica `forms/_schema`, sem partial própria); e o próprio plugin é o
  # driver dos aparelhos que cria (`read`/`write`), sem linha em
  # Drivers::REGISTRY nem em Polling::DEVICES (os dois perguntam a
  # `Integrations.device_driver`).
  #
  #   class FooPlugin < SchemaPlugin
  #     describe key: "foo", title: "Foo", icon: "bolt", description: "…"
  #     field :host, required: true
  #     field :token, secret: true
  #     def self.entries(integration) = [ entry(id: "foo:1", name: "Foo", points: [ point("power") ]) ]
  #     def self.read(device) = { "power" => 12.3 }   # campo do endereço do ponto → valor
  #     def self.write(point, value) = …                # pontos graváveis
  #   end
  #
  # Rótulo do campo e nome do ponto saem dos textos do plugin ("fields.<campo>",
  # "hints.<campo>", "points.<campo>"), com os comuns já aqui na base.
  class SchemaPlugin < Plugin
    Field = Data.define(:key, :type, :secret, :required, :default, :options)

    COMMON = {
      "pt-BR" => {
        required: "Preencha: %{field}.", read: "%{n} aparelho(s) lido(s).", read_failed: "Não deu para ler: %{error}", read_only: "Este ponto só lê, não recebe comando.",
        fields: { host: "Endereço (IP ou nome)", port: "Porta", username: "Usuário", password: "Senha", token: "Token", api_key: "Chave da API", url: "Endereço (URL)" },
        hints: { host: "192.168.0.50" },
        points: { power: "Potência", energy: "Energia", energy_today: "Energia hoje", voltage: "Tensão", current: "Corrente", temperature: "Temperatura",
                  humidity: "Umidade", battery: "Bateria", light: "Luz", brightness: "Brilho", color: "Cor", switch: "Liga/desliga", status: "Estado",
                  pressure: "Pressão", co2: "CO₂", noise: "Ruído", wind_speed: "Vento", rain: "Chuva", uptime: "Ligado há", volume: "Volume",
                  source: "Fonte", player: "Player", download: "Download", upload: "Upload", ping: "Latência" }
      },
      en: {
        required: "Fill in: %{field}.", read: "%{n} device(s) read.", read_failed: "Couldn't read: %{error}", read_only: "This point is read-only and takes no commands.",
        fields: { host: "Address (IP or name)", port: "Port", username: "Username", password: "Password", token: "Token", api_key: "API key", url: "Address (URL)" },
        hints: { host: "192.168.0.50" },
        points: { power: "Power", energy: "Energy", energy_today: "Energy today", voltage: "Voltage", current: "Current", temperature: "Temperature",
                  humidity: "Humidity", battery: "Battery", light: "Light", brightness: "Brightness", color: "Color", switch: "On/off", status: "Status",
                  pressure: "Pressure", co2: "CO₂", noise: "Noise", wind_speed: "Wind", rain: "Rain", uptime: "Up for", volume: "Volume",
                  source: "Source", player: "Player", download: "Download", upload: "Upload", ping: "Latency" }
      },
      es: {
        required: "Completa: %{field}.", read: "%{n} aparato(s) leído(s).", read_failed: "No se pudo leer: %{error}", read_only: "Este punto solo lee, no recibe comandos.",
        fields: { host: "Dirección (IP o nombre)", port: "Puerto", username: "Usuario", password: "Contraseña", token: "Token", api_key: "Clave de la API", url: "Dirección (URL)" },
        hints: { host: "192.168.0.50" },
        points: { power: "Potencia", energy: "Energía", energy_today: "Energía hoy", voltage: "Tensión", current: "Corriente", temperature: "Temperatura",
                  humidity: "Humedad", battery: "Batería", light: "Luz", brightness: "Brillo", color: "Color", switch: "Encendido", status: "Estado",
                  pressure: "Presión", co2: "CO₂", noise: "Ruido", wind_speed: "Viento", rain: "Lluvia", uptime: "Encendido hace", volume: "Volumen",
                  source: "Fuente", player: "Reproductor", download: "Descarga", upload: "Subida", ping: "Latencia" }
      }
    }.freeze
    texts COMMON

    class << self
      # Campo do formulário: :text, :number, :url, :textarea, :select (options) ou secreto
      # (`secret: true`, vai cifrado e vazio no Reconfigurar mantém o guardado).
      def field(key, type = :text, secret: false, required: false, default: nil, options: nil)
        own_fields << Field.new(key.to_s, secret ? :password : type, secret, required, default, options)
      end

      def own_fields = (@own_fields ||= [])
      def fields = (superclass.respond_to?(:fields) ? superclass.fields : []) + own_fields
      def field_label(key) = text("fields.#{key}")
      def field_hint(key) = text("hints.#{key}", default: "")
      def option_label(key, option) = text("options.#{key}.#{option}", default: option.to_s)
      def note = text(:note, default: "")

      def setup(site, form)
        missing = fields.find { |f| f.required && f.default.nil? && form[f.key].to_s.strip.blank? }
        return outcome(:form, alert: text(:required, field: field_label(missing.key))) if missing

        name = form[:name].to_s.squish.presence || [ title, form[:host].to_s.strip.presence ].compact.join(" ")
        login(new_integration(site, name: name), form)
      end

      def login(integration, form)
        plain = fields.reject(&:secret).to_h { |f| [ f.key, form[f.key].to_s.strip ] }.compact_blank
        integration.settings = integration.settings.merge(plain).then { |s| s.merge("account" => s["host"].presence || s["username"].presence || title) }
        values = fields.select(&:secret).to_h { |f| [ f.key, form[f.key].to_s.strip ] }.compact_blank
        integration.credentials = integration.secrets.merge(values).to_json if values.any?
        integration.save!
        r = Integrations.sync!(integration)
        outcome(:found, integration: integration, notice: text(:read, n: r[:found]))
      rescue Integrations::Error => e
        outcome(:found, integration: integration, alert: text(:read_failed, error: e.message))
      end

      # Achado na rede (primeira configuração): plugin com campo `host` entra sem formulário.
      def add_found(site, entry)
        host = entry["host"].to_s.strip.presence
        return unless host && fields.any? { |f| f.key == "host" } && fields.none? { |f| f.required && f.key != "host" }

        integration = new_integration(site, name: entry["name"].to_s.squish.presence || "#{title} #{host}")
        integration.settings = { "host" => host, "port" => entry["port"], "account" => host }.compact
        integration.save!
        Integrations.start_sync!(integration)
        integration
      end

      # Valor de um campo na integração (às claras ou cifrado), com o padrão do campo.
      def conf(integration, key)
        key = key.to_s
        integration.settings[key].presence || integration.secrets[key].presence || fields.find { |f| f.key == key }&.default
      end

      def inventory(integration) = Array(entries(integration)).compact
      def entries(_integration) = raise(NotImplementedError)
      def refresh(integration) = Drivers.refresh(integration)

      # Entrada de inventário (formato de `Integrations`).
      def entry(id:, name:, points:, **extra)
        { "id" => id, "kind" => driver, "name" => name, "manufacturer" => title, "online" => true, "poll_s" => 60,
          "address" => {}, "points" => points.compact }.merge(extra.transform_keys(&:to_s))
      end

      # Ponto pelo campo: nome dos textos ("points.<campo>" ou o `name` dado).
      def point(field, capability = "measure", name: nil, address: {}, **opts)
        { "name" => name || text("points.#{field}"), "capability" => capability, "address" => { "field" => field.to_s }.merge(address.transform_keys(&:to_s)) }
          .merge(opts.transform_keys(&:to_s))
      end

      # --- driver (ExecuteCommandJob e Polling chegam aqui pelo `device_driver`) ---
      def device_kinds = [ driver ]
      def device_driver(kind) = (self if device_kinds.include?(kind.to_s))

      # Aparelho → {campo => valor}; nil num campo = não informa agora.
      def read(_device) = {}
      def write(_point, _value) = raise(Integrations::Error, text(:read_only))
      # Comando com o nome (mídia: pause, next…); padrão: grava o valor novo.
      def command(point, _command, value) = write(point, value)

      def poll(device)
        values = read(device).to_h
        device.update_columns(status: "online", last_seen_at: Time.current)
        device.points.reject(&:disabled).each do |p|
          v = values[p.address["field"]]
          p.report!(v) unless v.nil?
        end
      end

      def unavailable!(device) = Drivers.offline!(device)
    end

    def execute(point, command, value)
      cmd = Points::Command.new(point, command, value)
      v = cmd.new_value
      # Mídia, controle remoto e robô (resto2: cômodos): o valor novo é o do ponto; o argumento do comando vai à parte.
      self.class.command(point, command, point.capability.in?(%w[media remote vacuum]) ? cmd.value : v)
      self.class.poll(point.device)
    end
  end
end
