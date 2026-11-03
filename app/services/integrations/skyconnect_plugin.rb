module Integrations
  # resto2 (grupo 9 #47/#55; o `homeassistant_sky_connect` e o
  # `homeassistant_connect_zbt2` do HA): o rádio USB da Nabu Casa (SkyConnect,
  # ZBT-1, ZBT-2) como aparelho, com o firmware dele. A sonda e a gravação
  # vão pelo supervisor num container de uma vez com a porta serial (perfil
  # `flasher`, universal-silabs-flasher); a versão nova vem dos releases da
  # Nabu Casa (Firmware::Providers::Silabs). O tipo escolhido aqui (Zigbee ou
  # Thread) diz qual firmware gravar: para o Zigbee2MQTT ou para o OTBR.
  class SkyconnectPlugin < SchemaPlugin
    describe key: "homeassistant_sky_connect", title: "Home Assistant Connect (SkyConnect, ZBT-1, ZBT-2)", icon: "chip",
             description: "O rádio USB da Nabu Casa: versão e tipo do firmware (Zigbee ou Thread) e gravar o firmware novo sem tirar do servidor."
    texts "pt-BR" => { fields: { device: "Porta serial", model: "Modelo", firmware: "Firmware" }, hints: { device: "/dev/serial/by-id/usb-Nabu_Casa_…" },
                       options: { model: { "skyconnect" => "SkyConnect / ZBT-1", "zbt2" => "ZBT-2" }, firmware: { "zigbee" => "Zigbee (Zigbee2MQTT)", "thread" => "Thread (OTBR)" } },
                       points: { radio: "Firmware do rádio" },
                       note: "Para ler ou gravar, o gravador precisa da porta livre: pare o Zigbee2MQTT ou o OTBR antes. Ligue o gravador uma vez com `docker compose --profile flasher build flasher`." },
          en: { title: "Home Assistant Connect (SkyConnect, ZBT-1, ZBT-2)", description: "Nabu Casa's USB radio: firmware version and type (Zigbee or Thread) and flashing new firmware without unplugging it.",
                fields: { device: "Serial port", model: "Model", firmware: "Firmware" }, hints: { device: "/dev/serial/by-id/usb-Nabu_Casa_…" },
                options: { model: { "skyconnect" => "SkyConnect / ZBT-1", "zbt2" => "ZBT-2" }, firmware: { "zigbee" => "Zigbee (Zigbee2MQTT)", "thread" => "Thread (OTBR)" } },
                points: { radio: "Radio firmware" },
                note: "To read or flash, the flasher needs the port free: stop Zigbee2MQTT or OTBR first. Enable the flasher once with `docker compose --profile flasher build flasher`." },
          es: { title: "Home Assistant Connect (SkyConnect, ZBT-1, ZBT-2)", description: "La radio USB de Nabu Casa: versión y tipo del firmware (Zigbee o Thread) y grabar el firmware nuevo sin desconectarla.",
                fields: { device: "Puerto serie", model: "Modelo", firmware: "Firmware" }, hints: { device: "/dev/serial/by-id/usb-Nabu_Casa_…" },
                options: { model: { "skyconnect" => "SkyConnect / ZBT-1", "zbt2" => "ZBT-2" }, firmware: { "zigbee" => "Zigbee (Zigbee2MQTT)", "thread" => "Thread (OTBR)" } },
                points: { radio: "Firmware de la radio" },
                note: "Para leer o grabar, el grabador necesita el puerto libre: detén Zigbee2MQTT u OTBR antes. Activa el grabador una vez con `docker compose --profile flasher build flasher`." }
    field :device, required: true
    field :model, :select, options: %w[skyconnect zbt2], default: "skyconnect"
    field :firmware, :select, options: %w[zigbee thread], default: "zigbee"
    usb({ vid: "10C4", pid: "EA60", description: "*skyconnect*" }, { vid: "10C4", pid: "EA60", description: "*zbt-1*" }, { vid: "303A", pid: "831A", description: "*zbt-2*" })

    # modelo → [repositório dos releases, prefixo do arquivo .gbl]
    MODELS = { "skyconnect" => %w[NabuCasa/silabs-firmware-builder skyconnect], "zbt2" => %w[NabuCasa/silabs-firmware-builder zbt2] }.freeze
    KINDS = { "zigbee" => "zigbee_ncp", "thread" => "openthread_rcp" }.freeze

    class << self
      def add_found(*) = nil # o achado vem com a porta, mas o tipo de firmware é escolha da pessoa

      def model(device) = MODELS.fetch(conf(device.integration, :model).to_s, MODELS["skyconnect"])
      def kind(device) = KINDS.fetch(conf(device.integration, :firmware).to_s, KINDS["zigbee"])

      def radio(action, body, timeout:)
        Apps::Supervisor.request(:post, "/system/radio/#{action}", body, timeout: timeout).fetch("data")
      rescue Apps::Supervisor::Error => e
        raise Integrations::Error, e.message
      end

      def label(data) = [ data["type"], data["version"] ].compact.join(" ")

      def entries(integration)
        port = conf(integration, :device)
        data = radio("probe", { device: port }, timeout: 180)
        model = conf(integration, :model)
        [ entry(id: "silabs:#{port}", name: option_label(:model, model), manufacturer: "Nabu Casa", model: option_label(:model, model), firmware: label(data),
                category: "Rede", address: { "port" => port }, poll_s: 86_400, points: [ point("radio", "text", writable: false, history: "on_change") ]) ]
      end

      # Ler o rádio abre a porta (que o Zigbee2MQTT/OTBR usam): só na varredura e depois de gravar.
      def read(device) = { "radio" => device.firmware.presence }

      def flash!(device_id, url, sha256)
        device = ActsAsTenant.without_tenant { Device.find(device_id) }
        ActsAsTenant.with_tenant(device.tenant) do
          data = radio("flash", { device: device.address["port"], url: url, sha256: sha256.presence }.compact, timeout: 900)
          device.update!(firmware: label(data))
          poll(device)
          Firmware.check!(device)
        rescue Integrations::Error => e
          Rails.logger.warn("[firmware] rádio #{device.name}: #{e.message}")
          point = Firmware.ensure_point!(device)
          point.report!((point.value.is_a?(Hash) ? point.value : {}).merge("state" => "available", "error" => e.message.truncate(200)))
        end
      end
    end
  end
end
