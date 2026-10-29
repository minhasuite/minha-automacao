module Miio
  # Robô aspirador Xiaomi pelo MIoT (spec de miot-spec.org; validado no X20 Max,
  # `xiaomi.vacuum.d109gl`). Pontos com `address` {siid, piid} e, quando é
  # código, `map` (código → texto). O ponto `vacuum` leva as ações
  # ({comando → [siid, aiid]}) e os cômodos do mapa ([{id, name}]). `role`
  # liga cada ponto ao widget do robô.
  module Vacuum
    STATES = {
      1 => "idle", 2 => "docked", 3 => "docked", 4 => "cleaning", 5 => "paused", 6 => "returning", 7 => "cleaning", 8 => "cleaning",
      9 => "docked", 10 => "cleaning", 11 => "docked", 12 => "docked", 13 => "docked", 14 => "docked", 15 => "error", 16 => "cleaning",
      17 => "cleaning", 18 => "paused", 19 => "paused", 20 => "cleaning", 21 => "returning"
    }.freeze
    DETAILS = {
      1 => "Parado", 2 => "Carregando", 3 => "Carregando para continuar", 4 => "Aspirando", 5 => "Pausado", 6 => "Voltando para a base",
      7 => "Indo lavar o pano", 8 => "Controle remoto", 9 => "Carregado", 10 => "Mapeando", 11 => "Atualizando",
      12 => "Base trabalhando", 13 => "Recarregando para continuar", 14 => "Base trabalhando", 15 => "Com erro",
      16 => "Aspirando e passando pano", 17 => "Passando pano", 18 => "Mapeamento pausado", 19 => "Volta à base pausada",
      20 => "Lavagem pausada", 21 => "Voltando para a base"
    }.freeze
    ACTIONS = {
      "start" => [ 2, 1 ], "continue" => [ 2, 8 ], "pause" => [ 2, 7 ], "stop" => [ 2, 2 ], "home" => [ 2, 3 ],
      "clean_rooms" => [ 2, 16 ], "wash_mop" => [ 2, 19 ], "dry_mop" => [ 2, 20 ], "empty" => [ 2, 18 ], "locate" => [ 6, 1 ]
    }.freeze
    # Ajustes da limpeza (papel → pt-BR por código), na ordem do widget.
    SETTINGS = {
      "mode" => [ "Modo", [ 2, 4 ], { 1 => "Só aspirar", 2 => "Só passar pano", 3 => "Aspirar e passar pano", 4 => "Aspirar antes do pano" } ],
      "suction" => [ "Potência", [ 2, 9 ], { 1 => "Silenciosa", 2 => "Normal", 3 => "Forte", 4 => "Máxima" } ],
      "water" => [ "Água do pano", [ 2, 10 ], { 0 => "Desligada", 1 => "Nível 1", 2 => "Nível 2", 3 => "Nível 3" } ],
      "route" => [ "Caminho", [ 2, 74 ], { 1 => "Rápido", 2 => "Padrão", 3 => "Profundo" } ],
      "times" => [ "Vezes", [ 2, 8 ], { 1 => "Uma vez", 2 => "Duas vezes", 3 => "Três vezes" } ]
    }.freeze
    PARTS = { "Escova principal" => [ 12, 1 ], "Escova lateral" => [ 13, 1 ], "Filtro" => [ 14, 1 ], "Pano" => [ 9, 1 ], "Saco de pó" => [ 19, 1 ] }.freeze

    module_function

    def address(siid, piid, role, **extra) = { "siid" => siid, "piid" => piid, "role" => role, **extra.transform_keys(&:to_s) }
    def map(hash) = hash.transform_keys(&:to_s)

    # Atributos dos pontos do robô; rooms = [{"id" => 5, "name" => "Sala de estar"}].
    def points(rooms)
      [
        { name: "Robô", capability: "vacuum", history: "on_change",
          address: address(2, 2, "vacuum", map: map(STATES), actions: ACTIONS, rooms: rooms) },
        { name: "Situação", capability: "text", writable: false, history: "on_change", address: address(2, 2, "detail", map: map(DETAILS)) },
        { name: "Bateria", capability: "measure", unit: "%", device_class: "battery", address: address(3, 1, "battery") },
        { name: "Erro", capability: "problem", address: address(2, 66, "fault", decode: "fault") },
        *SETTINGS.map do |role, (name, (s, p), codes)|
          { name: name, capability: "enum", options: codes.values, history: "on_change", address: address(s, p, role, map: map(codes)) }
        end,
        { name: "Área da limpeza", capability: "measure", unit: "m²", scale: 0.01, address: address(2, 6, "area") },
        { name: "Duração da limpeza", capability: "measure", unit: "min", scale: BigDecimal("1") / 60, address: address(2, 7, "duration") },
        *PARTS.map { |name, (s, p)| { name: name, capability: "measure", unit: "%", address: address(s, p, "part") } },
        { name: "Detergente", capability: "measure", unit: "%", address: address(18, 1, "detergent") }
      ]
    end

    # Valor bruto do MIoT → valor do ponto (nil = não sabe ler).
    def decode(point, raw)
      a = point.address
      return a["map"][raw.to_s] if a["map"]
      return fault?(raw) if a["decode"] == "fault"

      point.from_raw(raw)
    end

    # fault-ids: {"ts":…, "fault":[0]} → algum código diferente de zero.
    def fault?(raw)
      data = raw.is_a?(String) ? JSON.parse(raw) : raw
      Array(data.is_a?(Hash) ? data["fault"] : data).any? { |c| c.to_i.nonzero? }
    rescue JSON::ParserError
      nil
    end

    # Texto do ajuste → código (para gravar no robô).
    def encode(point, label)
      code = point.address["map"]&.key(label.to_s) or raise ArgumentError, "Opção inválida para #{point.name}."
      code.to_i
    end
  end
end
