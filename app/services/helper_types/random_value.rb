module HelperTypes
  # Aleatório (random do HA, ondaA1 A10): número inteiro entre o mínimo e o
  # máximo, sorteado de novo a cada minuto e no comando "Atualizar" (botão
  # e automação). Bom para simular presença ("acender uma luz qualquer").
  class RandomValue < Plugin
    describe key: "random", title: "Aleatório", icon: "sparkles", capability: "measure",
             description: "Um número sorteado de novo a cada minuto (ou quando pedir), entre o mínimo e o máximo: simular presença, variar a cena."
    fields %i[min_value max_value]
    texts "pt-BR" => { "form.min_value" => "Mínimo", "form.max_value" => "Máximo", order: "O mínimo precisa ser menor que o máximo.", summary: "de %{min} a %{max}", draw: "Sortear de novo" },
          en: { title: "Random", description: "A number drawn again every minute (or on demand), between the minimum and the maximum: simulate presence, vary the scene.",
                "form.min_value" => "Minimum", "form.max_value" => "Maximum", order: "The minimum must be less than the maximum.", summary: "from %{min} to %{max}", draw: "Draw again" },
          es: { title: "Aleatorio", description: "Un número sorteado de nuevo cada minuto (o cuando lo pidas), entre el mínimo y el máximo: simular presencia, variar la escena.",
                "form.min_value" => "Mínimo", "form.max_value" => "Máximo", order: "El mínimo debe ser menor que el máximo.", summary: "de %{min} a %{max}", draw: "Sortear de nuevo" }

    def self.form_spec = [ [ :min_value, :number, { value: ->(p) { p.address["min"] || 0 } } ], [ :max_value, :number, { value: ->(p) { p.address["max"] || 20 } } ] ]

    def self.assign(point, form)
      min = (form.key?("min_value") ? number(form["min_value"]) : point.address["min"])&.to_i || 0
      max = (form.key?("max_value") ? number(form["max_value"]) : point.address["max"])&.to_i || 20
      point.data_type = "integer"
      point.writable = true
      point.address = point.address.merge("min" => min, "max" => max)
      point.errors.add(:base, text(:order)) unless min < max
    end

    def self.draw(point) = rand(point.address["min"].to_i..point.address["max"].to_i)
    def self.initial_value(point) = draw(point)
    def self.commands(_point) = %w[press]
    def self.command_labels = { "press" => text(:draw) }
    def self.new_value(cmd) = draw(cmd.point)
    def self.execute(point, _command, _value) = point.report!(draw(point))
    def self.clocked? = true
    def self.tick(point, _now) = point.report!(draw(point))
    def self.summary(point) = text(:summary, min: point.address["min"], max: point.address["max"])
  end
end
