module Integrations
  # Android TV / Fire TV / Google TV por ADB na rede (Pacote 1, opcional):
  # liga, desliga, teclas de mídia, app aberto e abrir um endereço
  # (Drivers::Adb). Pede "Depuração de rede" ligada e, na primeira vez,
  # "Permitir" na tela da TV.
  class AdbPlugin < MediaLanPlugin
    describe key: "adb", title: "Android TV / Fire TV (ADB)", icon: "desktop-computer",
             description: "TV ou caixa Android com a depuração pela rede ligada: liga, desliga, volume, pausar e app aberto. Na primeira vez, permita na tela da TV."
    texts en: { title: "Android TV / Fire TV (ADB)", description: "Android TV or box with network debugging on: power, volume, pause and the open app. The first time, allow it on the TV screen." },
          es: { title: "Android TV / Fire TV (ADB)", description: "TV o caja Android con la depuración por red activada: encender, apagar, volumen, pausa y app abierta. La primera vez, permítelo en la pantalla de la TV." }
    port Drivers::Adb::PORT
    PAIR_S = 30

    def self.probe(integration)
      key = Drivers::Adb.key(integration)
      out = Drivers::Adb::Client.new(host_of(integration), port_of(integration), key, pair_timeout: PAIR_S)
                                .shell("getprop ro.serialno; getprop ro.product.model; getprop ro.product.manufacturer")
      serial, model, maker = out.lines.map(&:strip)
      Drivers::MediaLan.entry(integration, "adb:#{serial.presence || host_of(integration)}", kind: "adb", supports: Drivers::Adb::SUPPORTS,
                              port: port_of(integration), manufacturer: maker.presence, model: model.presence)
    end
  end
end
