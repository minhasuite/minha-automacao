module Integrations
  # LG webOS (Pacote 1): volume, app aberto, controles e desligar pela rede
  # (Drivers::Webos). A primeira leitura pede o pareamento na tela da TV.
  class WebosPlugin < MediaLanPlugin
    describe key: "webos", title: "TV LG (webOS)", icon: "desktop-computer",
             description: "TV LG na rede: volume, app aberto, pausar, desligar e abrir um endereço. Na primeira vez, aceite o pedido na tela da TV."
    texts en: { title: "LG TV (webOS)", description: "LG TV on your network: volume, open app, pause, power off and open a URL. The first time, accept the request on the TV screen." },
          es: { title: "TV LG (webOS)", description: "TV LG en la red: volumen, app abierta, pausa, apagar y abrir una dirección. La primera vez, acepta la solicitud en la pantalla de la TV." }
    port Drivers::Webos::PORT
    ssdp "urn:lge-com:service:webos-second-screen:1"
    PAIR_S = 60

    def self.probe(integration)
      host = host_of(integration)
      Drivers::Webos.session(integration, host, port_of(integration), pair_timeout: PAIR_S) do |s|
        info = s.call("ssap://system/getSystemInfo")
        net = begin
          s.call("ssap://com.webos.service.connectionmanager/getinfo")
        rescue Drivers::MediaLan::Error
          {}
        end
        mac = net.dig("wiredInfo", "macAddress").presence || net.dig("wifiInfo", "macAddress").presence
        supports = Drivers::Webos::SUPPORTS + (mac ? %w[on] : [])
        Drivers::MediaLan.entry(integration, "webos:#{mac || host}", kind: "webos", supports: supports, port: port_of(integration),
                                address: { "mac" => mac }, manufacturer: "LG", model: info["modelName"])
      end
    end
  end
end
