module HelperTypes
  # Liga/desliga (input_boolean do HA).
  class Toggle < Plugin
    describe key: "toggle", title: "Liga/desliga", icon: "switch-horizontal", capability: "onoff",
             description: "Uma chave que você liga e desliga: modo visita, férias, não perturbe."
    fields %i[initial]

    def self.assign(point, form)
      point.writable = true
      point.address = point.address.merge("initial" => ActiveModel::Type::Boolean.new.cast(form["initial"]) || false) if form.key?("initial")
    end

    def self.initial_value(point) = point.address["initial"] || false
    def self.summary(point) = "começa #{point.address['initial'] ? 'ligado' : 'desligado'}"
  end
end
