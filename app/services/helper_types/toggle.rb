module HelperTypes
  # Liga/desliga (input_boolean do HA).
  class Toggle < Plugin
    describe key: "toggle", title: "Liga/desliga", icon: "switch-horizontal", capability: "onoff",
             description: "Uma chave que você liga e desliga: modo visita, férias, não perturbe."
    fields %i[initial]
    texts "pt-BR" => { on: "começa ligado", off: "começa desligado" },
          en: { title: "On/off", description: "A switch you turn on and off: guest mode, vacation, do not disturb.", on: "starts on", off: "starts off" },
          es: { title: "Encendido/apagado", description: "Un interruptor que enciendes y apagas: modo visita, vacaciones, no molestar.",
                on: "empieza encendido", off: "empieza apagado" }

    def self.assign(point, form)
      point.writable = true
      point.address = point.address.merge("initial" => ActiveModel::Type::Boolean.new.cast(form["initial"]) || false) if form.key?("initial")
    end

    def self.initial_value(point) = point.address["initial"] || false
    def self.summary(point) = text(point.address["initial"] ? :on : :off)
  end
end
