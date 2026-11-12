require "rails_helper"

RSpec.describe AppCatalog do
  def manifest(extra = {})
    AppCatalog::Manifest.new("teste", { "name" => "Teste", "category" => "X", "icon" => "cube", "description" => "d",
                                        "image" => "org/teste", "version" => "1.0.0", "network" => "bridge" }.merge(extra))
  end

  it "todo manifesto traz en e es para categoria, descrição e rótulo/ajuda das opções" do
    missing = described_class.all.flat_map do |m|
      AppCatalog::LOCALES.flat_map do |l|
        texts = m.data.dig("i18n", l) || {}
        own = %w[category description].reject { |f| texts[f].present? }
        opts = m.options.flat_map { |o| %w[label help].select { |f| o[f] && texts.dig("options", o["key"], f).blank? }.map { |f| "options.#{o['key']}.#{f}" } }
        (own + opts).map { |f| "#{m.key} #{l}.#{f}" }
      end
    end
    expect(missing).to eq([])
    I18n.with_locale(:en) { expect(described_class.find("node_red").category).to eq("Automation") }
    expect(described_class.find("node_red").category).to eq("Automação")
  end

  it "carrega todos os manifestos do catálogo, com ícone que existe e porta única" do
    keys = described_class.all.map(&:key)
    expect(keys).to include("mosquitto", "go2rtc", "zigbee2mqtt", "node_red", "esphome", "frigate", "music_assistant", "code_server", "uptime_kuma")
    described_class.all.each { |m| expect(Rails.root.join("app/assets/images/icons/#{m.icon}.svg")).to exist }
    hosts = described_class.all.flat_map { |m| m.ports.map { |p| [ p["host"], p.fetch("protocol", "tcp") ] } }
    expect(hosts).to eq(hosts.uniq)
  end

  it "app do sistema tem a mesma versão do serviço no compose" do
    compose = YAML.safe_load_file(Rails.root.join("docker-compose.local.yml"), aliases: true)
    described_class.all.select(&:system?).each do |m|
      expect(compose.dig("services", m.system_service, "image")).to eq(m.image_ref)
    end
  end

  it "procura por texto e categoria" do
    expect(described_class.search("kuma").map(&:key)).to eq([ "uptime_kuma" ])
    expect(described_class.search("", "Câmeras").map(&:key)).to contain_exactly("go2rtc", "frigate", "compreface", "double_take", "scrypted")
    expect(described_class.search(nil).size).to eq(described_class.all.size)
    expect(described_class.categories).to include("Monitoramento")
    expect(described_class.find("nada")).to be_nil
  end

  it "recusa manifesto com campo arbitrário, imagem sem versão fixa, porta reservada ou segredo fora da lista" do
    expect(manifest).to be_a(AppCatalog::Manifest)
    [ { "privileged" => true }, { "version" => "latest" }, { "version" => 1.2 }, { "image" => "Org/X;rm" },
      { "ports" => [ { "container" => 80, "host" => 5432 } ] }, { "ports" => [ { "container" => 80, "host" => 22 } ] },
      { "server_env" => { "X" => "DB_PASSWORD" } }, { "network" => "host" }, { "env" => { "x" => "1" } },
      { "volumes" => [ { "name" => "d", "path" => "../etc" } ] }, { "web_ui" => { "port" => 9999 } },
      { "options" => [ { "key" => "x", "label" => "X", "type" => "file", "env" => "X" } ] },
      { "options" => [ { "key" => "x", "label" => "X", "type" => "string" } ] },
      { "health" => { "test" => "curl" } }, { "shm_mb" => 99_999 }, { "system" => "Bad Name" } ].each do |bad|
      expect { manifest(bad) }.to raise_error(AppCatalog::Invalid), bad.inspect
    end
    expect { AppCatalog::Manifest.new("Bad-Key", {}) }.to raise_error(AppCatalog::Invalid)
  end

  describe "opções" do
    let(:app) do
      manifest("options" => [
                 { "key" => "nome", "label" => "Nome", "type" => "string", "env" => "NOME", "pattern" => '\A\w+\z', "default" => "casa" },
                 { "key" => "porta", "label" => "Porta", "type" => "integer", "env" => "PORTA", "min" => 1, "max" => 10 },
                 { "key" => "liga", "label" => "Liga", "type" => "boolean", "env" => "LIGA", "default" => false },
                 { "key" => "modo", "label" => "Modo", "type" => "enum", "env" => "MODO", "choices" => %w[a b] },
                 { "key" => "senha", "label" => "Senha", "type" => "string", "env" => "SENHA", "secret" => true },
                 { "key" => "usb", "label" => "USB", "type" => "device", "path" => "/dev/zigbee", "required" => true }
               ])
    end

    it "limpa, converte e valida pelo schema (chave fora do schema é ignorada)" do
      clean, errors = app.clean_options("nome" => "", "porta" => "3", "liga" => "1", "modo" => "b", "senha" => "x",
                                        "usb" => "/dev/serial/by-id/usb-ITead-if00", "Image" => "evil")
      expect(errors).to be_empty
      expect(clean).to eq("nome" => "casa", "porta" => 3, "liga" => true, "modo" => "b", "senha" => "x", "usb" => "/dev/serial/by-id/usb-ITead-if00")
      expect(app.public_options(clean)["senha"]).to be_nil

      _, errors = app.clean_options({ "nome" => "a b", "porta" => "99", "modo" => "c", "usb" => "/etc/passwd" })
      expect(errors.keys).to contain_exactly("nome", "porta", "modo", "usb")
      _, errors = app.clean_options(nil)
      expect(errors).to eq("usb" => "obrigatório")
      clean, = app.clean_options({ "usb" => "/dev/ttyUSB0", "senha" => "" }, { "senha" => "antiga" })
      expect(clean["senha"]).to eq("antiga")
    end

    it "Zigbee2MQTT aceita coordenador pela rede (Dongle Max) no lugar da USB" do
      z2m = AppCatalog.find("zigbee2mqtt")
      opts, errors = z2m.clean_options({ "network_address" => "tcp://192.168.68.50:6638", "adapter" => "ember" })
      expect(errors).to be_empty
      body = z2m.container_body(opts, network: "bridge", restart: "no", server_env: {})
      expect(body["Env"]).to include("ZIGBEE2MQTT_CONFIG_SERIAL_PORT=tcp://192.168.68.50:6638", "ZIGBEE2MQTT_CONFIG_SERIAL_ADAPTER=ember")
      expect(body["Env"]).not_to include("ZIGBEE2MQTT_CONFIG_SERIAL_PORT=/dev/zigbee")
      expect(body["HostConfig"]["Devices"]).to eq([])
      expect(z2m.clean_options({ "network_address" => "http://x; rm -rf /" }).last).to have_key("network_address")
      usb, = z2m.clean_options({ "serial_port" => "/dev/ttyUSB0" })
      expect(z2m.container_body(usb, network: "bridge", restart: "no", server_env: {})["Env"]).to include("ZIGBEE2MQTT_CONFIG_SERIAL_PORT=/dev/zigbee")
    end

    it "monta o container só com o que o manifesto prevê" do
      app = manifest("ports" => [ { "container" => 3001, "host" => 3001 } ], "volumes" => [ { "name" => "data", "path" => "/data" } ],
                     "env" => { "TZ" => "America/Sao_Paulo" }, "server_env" => { "MQTT_PASS" => "MQTT_PASSWORD" },
                     "health" => { "test" => [ "CMD", "true" ] }, "shm_mb" => 128,
                     "options" => [ { "key" => "usb", "label" => "USB", "type" => "device", "path" => "/dev/zigbee" },
                                    { "key" => "tz", "label" => "TZ", "type" => "string", "env" => "TZ" } ])
      body = app.container_body({ "usb" => "/dev/ttyACM0", "tz" => "UTC" }, network: "bridge", restart: "no", server_env: { "MQTT_PASSWORD" => "s" })
      expect(body["Image"]).to eq("org/teste:1.0.0")
      expect(body["Env"]).to contain_exactly("TZ=UTC", "MQTT_PASS=s")
      expect(body["Labels"]).to include(AppCatalog::LABEL => "teste", "minha-automacao.version" => "1.0.0")
      hc = body["HostConfig"]
      expect(hc).to include("Binds" => [ "ma-app-teste-data:/data" ], "NetworkMode" => "bridge", "Privileged" => false, "ShmSize" => 128 * 1024 * 1024)
      expect(hc["PortBindings"]).to eq("3001/tcp" => [ { "HostPort" => "3001" } ])
      expect(hc["Devices"]).to eq([ { "PathOnHost" => "/dev/ttyACM0", "PathInContainer" => "/dev/zigbee", "CgroupPermissions" => "rwm" } ])
      expect(body["Healthcheck"]["Test"]).to eq([ "CMD", "true" ])
    end
  end
end
