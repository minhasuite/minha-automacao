module Integrations
  # Broadlink IR/RF (Pacote 1): um aparelho por integração, achado pelo
  # "hello" na rede (só lê). Vira um ponto `remote` ("Controle"), onde os
  # botões são aprendidos e enviados (Remotes), e os sensores do RM4 Pro.
  class BroadlinkPlugin < LanPlugin
    describe key: "broadlink", title: "Broadlink (IR/RF)", icon: "status-online",
             description: "Controle remoto universal Broadlink (RM mini, RM4): aprende os botões dos controles da casa e manda de novo pelo painel e pelas automações."
    texts "pt-BR" => { locked: "Aparelho bloqueado: desbloqueie no app Broadlink (Propriedades → Bloquear aparelho)." },
          en: { title: "Broadlink (IR/RF)", description: "Broadlink universal remote (RM mini, RM4): learns the buttons of your remotes and replays them from dashboards and automations.", locked: "Device locked: unlock it in the Broadlink app (Properties → Lock device)." },
          es: { title: "Broadlink (IR/RF)", description: "Control remoto universal Broadlink (RM mini, RM4): aprende los botones de los controles de la casa y los repite desde los paneles y las automatizaciones.", locked: "Aparato bloqueado: desbloquéalo en la app Broadlink (Propiedades → Bloquear aparato)." }
    port ::Broadlink::PORT

    def self.discovers? = true

    def self.discover
      ::Broadlink.discover.map do |d|
        { "name" => d["name"].presence || "Broadlink", "host" => d["host"], "port" => ::Broadlink::PORT, "txt" => { "md" => ::Broadlink.model(d["devtype"])["name"] } }
      end
    end

    def self.probe(integration)
      host = host_of(integration)
      info = ::Broadlink.hello(host, port_of(integration))
      raise Integrations::Error, text(:locked) if info["locked"]

      model = ::Broadlink.model(info["devtype"])
      address = { "host" => host, "port" => port_of(integration), "mac" => info["mac"], "devtype" => info["devtype"] }
      ::Broadlink::Client.new(host: host, port: address["port"], mac: info["mac"], devtype: info["devtype"]).auth!
      { "id" => info["mac"], "kind" => "broadlink", "name" => info["name"].presence || model["name"], "manufacturer" => "Broadlink",
        "model" => model["name"], "category" => "Controle IR/RF", "address" => address, "poll_s" => model["sensors"] ? 300 : 1800,
        "points" => points(model) }
    rescue ::Broadlink::Error, *NET_ERRORS => e
      raise Integrations::Error, e.message
    end

    def self.points(model)
      list = [ { "name" => "Controle", "capability" => "remote", "history" => "none", "address" => {} } ]
      return list unless model["sensors"]

      list + [ { "name" => "Temperatura", "capability" => "measure", "unit" => "°C", "device_class" => "temperature", "address" => { "sensor" => "temperature" } },
               { "name" => "Umidade", "capability" => "measure", "unit" => "%", "device_class" => "humidity", "address" => { "sensor" => "humidity" } } ]
    end
  end
end
