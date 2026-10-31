module HelperTypes
  # Interface comum de um tipo de helper. Subclasse = plugin: descreve-se
  # (`describe`), monta o ponto pelo formulário (`assign`, erro em
  # `point.errors`), diz o valor inicial, os comandos e o valor de cada
  # comando. Helper calculado (`sourced?`) guarda os pontos de origem em
  # `address["sources"]` e se refaz em `refresh!` quando um deles muda.
  class Plugin
    class << self
      attr_reader :key, :title, :icon, :description, :capability

      def describe(key:, title:, icon:, description:, capability:)
        @key = key
        @title = title
        @icon = icon
        @description = description
        @capability = capability
      end

      # Campos do formulário do tipo (os de `params.permit`), além de nome, ícone, área e restaurar.
      def fields(list = nil)
        @fields = list if list
        @fields || []
      end

      # Formulário (hash de texto) → atributos do ponto.
      def assign(_point, _form) = nil

      def initial_value(_point) = nil

      # Comandos aceitos (a lista que o editor de automações e os widgets mostram).
      def commands(point) = point.writable ? Points::Command::COMMANDS.fetch(point.capability, []) : []

      # Comandos sem valor que as telas mostram como botões agora (contador,
      # temporizador conforme o estado). Os de valor (set/select) e o liga/
      # desliga a tela já desenha pela capacidade.
      def actions(_point) = []

      # Texto do valor na tela (nil = o texto comum da capacidade).
      def value_text(_point) = nil

      # Rótulos próprios de comando no editor ({comando → rótulo}).
      def command_labels = {}

      # Valor novo para o comando (levanta Points::Command::Error se não serve).
      def new_value(cmd) = cmd.by_capability

      # Driver virtual: aplica o comando já validado.
      def execute(point, command, value) = point.report!(Points::Command.new(point, command, value).new_value)

      # Valor escrito de fora (POST /points/:id/value), já no tipo do ponto.
      def check(point, value)
        set = (commands(point) & %w[set select]).first or return value
        Points::Command.new(point, set, value).new_value
      end

      def sourced? = false

      # Comando no helper comanda outros pontos (grupo)? Na sombra (F10), só o
      # helper que não comanda nada roda de verdade.
      def drives_points? = false
      def refresh!(_point) = nil

      # Reinício sem "restaurar": volta ao inicial.
      def reset!(point) = point.report!(initial_value(point))

      # Resumo da configuração na lista ("0 a 100 °C, passo 1").
      def summary(_point) = nil

      # Para os plugins: número do formulário ("2,5" → 2.5; vazio → nil).
      def number(raw) = raw.to_s.strip.empty? ? nil : Float(raw.to_s.tr(",", "."), exception: false)

      def invalid!(message) = raise(Points::Command::Error.new(:invalid_value, message))
    end
  end
end
