module HelperTypes
  # Lista de opções (input_select do HA).
  class Select < Plugin
    describe key: "select", title: "Lista de opções", icon: "view-list", capability: "enum",
             description: "Uma escolha entre opções fixas: modo da casa (Casa, Fora, Noite)."
    fields %i[options_text]
    texts en: { title: "Option list", description: "One choice among fixed options: house mode (Home, Away, Night)." },
          es: { title: "Lista de opciones", description: "Una elección entre opciones fijas: modo de la casa (Casa, Fuera, Noche)." }

    def self.assign(point, form)
      point.writable = true
      point.options_text = form["options_text"] if form.key?("options_text")
      point.options = point.options.uniq
    end

    def self.initial_value(point) = point.option_values.first
    def self.summary(point) = point.option_values.join(", ").truncate(60)
  end
end
