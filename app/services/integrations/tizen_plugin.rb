module Integrations
  # Samsung Tizen (Pacote 1): teclas do controle (volume, mudo, play/pausa,
  # desligar) pela rede (Drivers::Tizen). A primeira leitura pede para
  # permitir na tela da TV.
  class TizenPlugin < MediaLanPlugin
    describe key: "tizen", title: "TV Samsung (Tizen)", icon: "desktop-computer",
             description: "TV Samsung na rede: ligada ou não, volume, mudo, pausar e desligar. Na primeira vez, permita o acesso na tela da TV."
    port Drivers::Tizen::PORT
    PAIR_S = 30

    def self.probe(integration)
      host = host_of(integration)
      info = Drivers::Tizen.info(host)
      Drivers::Tizen.remote(integration, host, port_of(integration), timeout: PAIR_S) { nil } # pareia e guarda o token
      mac = info["wifiMac"].presence
      Drivers::MediaLan.entry(integration, "tizen:#{info['id'].presence || host}", kind: "tizen", port: port_of(integration),
                              supports: Drivers::Tizen::SUPPORTS + (mac ? %w[on] : []), address: { "mac" => mac },
                              manufacturer: "Samsung", model: info["modelName"], name: integration.name)
    end
  end
end
