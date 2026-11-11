module Integrations
  # ESPresense (placas ESP32 por cômodo + o app ESPresense Companion):
  # cômodo atual de cada celular, relógio ou chaveiro Bluetooth, pelo MQTT
  # da casa. Lógica no descobridor ::Espresense (Mqtt::Listener):
  # - `<tópico>/companion/<id>`: o cômodo que o Companion calculou;
  # - `<tópico>/devices/<id>/<cômodo>`: a distância medida por cada placa;
  #   sem o Companion, o cômodo é o da placa mais perto (dentro do alcance e
  #   do tempo).
  # Só os aparelhos listados entram (a vizinhança tem muito Bluetooth). Cada
  # um vira aparelho com o ponto "Cômodo atual" (rastreador People::Trackers::Room);
  # cada cômodo listado vira o sensor "Ocupado" (alguém listado está lá).
  class EspresensePlugin < SchemaPlugin
    describe key: "espresense", title: "ESPresense (cômodo por Bluetooth)", icon: "status-online",
             description: "Em que cômodo está cada celular, relógio ou chaveiro, pelas placas ESPresense: cômodo atual por pessoa e ocupação por cômodo."
    texts "pt-BR" => { fields: { topic: "Tópico MQTT", devices: "Aparelhos (id = nome, um por linha)", rooms: "Cômodos para ocupação (um por linha)",
                                 max_distance: "Alcance (metros)", timeout_s: "Some depois de (segundos)" },
                       hints: { topic: "espresense", devices: "irk:1234abcd = Celular do Herlon", rooms: "sala\nquarto", max_distance: "5", timeout_s: "30" },
                       points: { room: "Cômodo atual", distance: "Distância", occupied: "Ocupado" }, occupancy: "Ocupação: %{room}",
                       no_devices: "Informe ao menos um aparelho (id do ESPresense = nome)." },
          en: { title: "ESPresense (room by Bluetooth)", description: "Which room each phone, watch or tag is in, through the ESPresense boards: current room per person and occupancy per room.",
                fields: { topic: "MQTT topic", devices: "Devices (id = name, one per line)", rooms: "Rooms for occupancy (one per line)",
                          max_distance: "Range (meters)", timeout_s: "Gone after (seconds)" },
                hints: { topic: "espresense", devices: "irk:1234abcd = Herlon's phone", rooms: "living\nbedroom", max_distance: "5", timeout_s: "30" },
                points: { room: "Current room", distance: "Distance", occupied: "Occupied" }, occupancy: "Occupancy: %{room}",
                no_devices: "Enter at least one device (ESPresense id = name)." },
          es: { title: "ESPresense (cuarto por Bluetooth)", description: "En qué cuarto está cada celular, reloj o llavero, por las placas ESPresense: cuarto actual por persona y ocupación por cuarto.",
                fields: { topic: "Tema MQTT", devices: "Aparatos (id = nombre, uno por línea)", rooms: "Cuartos para ocupación (uno por línea)",
                          max_distance: "Alcance (metros)", timeout_s: "Desaparece después de (segundos)" },
                hints: { topic: "espresense", devices: "irk:1234abcd = Celular de Herlon", rooms: "sala\ndormitorio", max_distance: "5", timeout_s: "30" },
                points: { room: "Cuarto actual", distance: "Distancia", occupied: "Ocupado" }, occupancy: "Ocupación: %{room}",
                no_devices: "Indica al menos un aparato (id de ESPresense = nombre)." }
    field :topic, default: "espresense"
    field :devices, :textarea, required: true
    field :rooms, :textarea
    field :max_distance, :number, default: 5
    field :timeout_s, :number, default: 30

    class << self
      def tracked(integration)
        conf(integration, :devices).to_s.lines.filter_map do |l|
          id, name = l.split("=", 2).map(&:squish)
          [ id, name.presence || id ] if id.to_s.match?(/\A[\w:.-]{1,80}\z/)
        end.uniq(&:first).first(50)
      end

      def rooms(integration) = conf(integration, :rooms).to_s.split(/[\n,;]+/).map { |r| Espresense.room_id(r) }.compact_blank.uniq.first(50)
      def prefix(integration) = conf(integration, :topic).to_s.delete_suffix("/").presence || "espresense"

      def entries(integration)
        list = tracked(integration).presence or raise(Integrations::Error, text(:no_devices))
        devices = list.map do |id, name|
          entry(id: "espresense:#{prefix(integration)}:#{id}", name: name, manufacturer: "ESPresense", poll_s: 60, address: { "id" => id },
                points: [ point("room", "text", address: { "tracker" => "room" }, icon: "location-marker"), point("distance", unit: "m", state_class: "measurement") ])
        end
        devices + rooms(integration).map do |r|
          entry(id: "espresense:#{prefix(integration)}:room:#{r}", name: text(:occupancy, room: r.tr("_", " ").capitalize), manufacturer: "ESPresense", poll_s: 60,
                room: r.tr("_", " "), address: { "room" => r }, points: [ point("occupied", "motion", device_class: "occupancy", address: { "room" => r }) ])
        end
      end

      # Leitura periódica (também tira de um cômodo quem sumiu): o estado vive na memória do ouvinte.
      def read(device)
        i = device.integration
        if (room = device.address["room"])
          { "occupied" => Espresense.occupied?(prefix(i), room, i) }
        else
          now = Espresense.current(prefix(i), device.address["id"], i)
          { "room" => now[0], "distance" => now[1] }
        end
      end
    end
  end
end
