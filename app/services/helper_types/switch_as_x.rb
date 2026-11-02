module HelperTypes
  # Mudar o tipo de um interruptor (switch_as_x do HA, ondaA1 A10): o
  # liga/desliga de uma tomada ou relé aparece como luz, ventilador, sirene,
  # válvula ou tomada (o `device_class`), com ícone e lugar certos no painel,
  # na voz e nas pontes. Espelha a origem; o comando vai para ela. "Inverter"
  # serve para relé normalmente fechado.
  class SwitchAsX < Plugin
    KINDS = { "light" => "light-bulb", "fan" => "fan", "siren" => "speakerphone", "valve" => "switch-horizontal", "outlet" => "lightning-bolt" }.freeze

    describe key: "switch_as_x", title: "Mudar o tipo de um interruptor", icon: "switch-horizontal", capability: "onoff",
             description: "Faz uma tomada ou relé aparecer como luz, ventilador, sirene ou válvula, e repassa o comando."
    fields %i[source kind invert]
    texts "pt-BR" => { "form.source" => "Interruptor de origem", "form.kind" => "Mostrar como", "form.invert" => "Inverter (relé normalmente fechado)",
                       "kind.light" => "Luz", "kind.fan" => "Ventilador", "kind.siren" => "Sirene", "kind.valve" => "Válvula", "kind.outlet" => "Tomada",
                       pick: "Escolha um liga/desliga que receba comando.", summary: "%{source} como %{kind}" },
          en: { title: "Change device type of a switch", description: "Makes a plug or relay show up as a light, fan, siren or valve, and forwards the command.",
                "form.source" => "Source switch", "form.kind" => "Show as", "form.invert" => "Invert (normally closed relay)",
                "kind.light" => "Light", "kind.fan" => "Fan", "kind.siren" => "Siren", "kind.valve" => "Valve", "kind.outlet" => "Outlet",
                pick: "Choose an on/off point that accepts commands.", summary: "%{source} as %{kind}" },
          es: { title: "Cambiar el tipo de un interruptor", description: "Hace que un enchufe o relé aparezca como luz, ventilador, sirena o válvula, y reenvía el comando.",
                "form.source" => "Interruptor de origen", "form.kind" => "Mostrar como", "form.invert" => "Invertir (relé normalmente cerrado)",
                "kind.light" => "Luz", "kind.fan" => "Ventilador", "kind.siren" => "Sirena", "kind.valve" => "Válvula", "kind.outlet" => "Enchufe",
                pick: "Elige un encendido/apagado que reciba comandos.", summary: "%{source} como %{kind}" }

    def self.form_spec
      [ [ :source, :point, { index: 0, filter: ->(p) { p.capability == "onoff" && p.writable } } ],
        [ :kind, :select, { choices: -> { KINDS.keys.index_with { |k| text("kind.#{k}") } } } ], [ :invert, :bool ] ]
    end

    def self.assign(point, form)
      src = point.site.points.find_by(id: form["source"].presence || point.address.dig("sources", 0))
      return point.errors.add(:base, text(:pick)) unless src && src.capability == "onoff" && src.writable && src.id != point.id

      kind = form.fetch("kind", point.address["kind"]).to_s.presence_in(KINDS.keys) || "light"
      invert = form.key?("invert") ? ActiveModel::Type::Boolean.new.cast(form["invert"]) == true : point.address["invert"] == true
      point.data_type = "bool"
      point.writable = true
      point.device_class = kind
      point.icon ||= KINDS[kind]
      point.risk = src.risk # o risco é o da origem (sirene, válvula)
      point.address = point.address.merge("sources" => [ src.id ], "kind" => kind, "invert" => invert)
    end

    def self.sourced? = true
    def self.drives_points? = true

    def self.refresh!(point)
      src = source(point)
      return point.report!(point.value, quality: "unavailable") unless src&.quality == "good" && [ true, false ].include?(src.value)

      point.report!(point.address["invert"] ? !src.value : src.value)
    end

    def self.execute(point, command, _value)
      want = command == "toggle" ? !point.value : command == "on"
      want = !want if point.address["invert"]
      src = source(point) or raise Points::Command::Error.new(:member_failed, text(:pick))
      parent = point.commands.where(status: "sent").order(:created_at).last
      c = Points::Command.call(src, want ? "on" : "off", nil, source: parent&.source || "automation", user: parent&.user)
      raise Points::Command::Error.new(:member_failed, c.error) if c.error
    end

    def self.summary(point) = text(:summary, source: source(point)&.name.to_s, kind: text("kind.#{point.address['kind']}").downcase)
  end
end
