module HelperTypes
  # Interface comum de um tipo de helper. Subclasse = plugin: descreve-se
  # (`describe`), monta o ponto pelo formulário (`assign`, erro em
  # `point.errors`), diz o valor inicial, os comandos e o valor de cada
  # comando. Helper calculado (`sourced?`) guarda os pontos de origem em
  # `address["sources"]` e se refaz em `refresh!` quando um deles muda.
  class Plugin
    extend PluginTexts
    translates :title, :description
    texts "pt-BR" => { pick_source: "Escolha um ponto numérico de origem.", decimals: "Casas decimais de 0 a 6." },
          en: { pick_source: "Choose a numeric source point.", decimals: "Decimal places must be from 0 to 6." },
          es: { pick_source: "Elige un punto numérico de origen.", decimals: "Los decimales van de 0 a 6." }

    # Fator do prefixo de unidade (k = mil) e segundos da unidade de tempo (integral e derivada).
    PREFIXES = { "" => 1, "k" => 1e3, "M" => 1e6, "G" => 1e9 }.freeze
    TIME_UNITS = { "s" => 1, "min" => 60, "h" => 3600, "d" => 86_400 }.freeze

    class << self
      attr_reader :key, :icon, :capability

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

      # ondaA1 (A10): campos do formulário genérico (web/site_helpers/forms/_generic):
      # [[campo, tipo, opções]]; tipo :source, :point, :number, :text, :select, :bool ou :textarea.
      def form_spec = []

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

      # Fim de um tempo agendado no HelperTimerJob (padrão: nada).
      def finish_due!(_point, _stamp) = nil

      # Comando no helper comanda outros pontos (grupo)? Na sombra (F10), só o
      # helper que não comanda nada roda de verdade.
      def drives_points? = false
      def refresh!(_point) = nil

      # Reinício sem "restaurar": volta ao inicial.
      def reset!(point) = point.report!(initial_value(point))

      # Resumo da configuração na lista ("0 a 100 °C, passo 1").
      def summary(_point) = nil

      # Configuração que a API mostra (Pacote 3: sem segredo, como o hash do código).
      def public_address(point) = point.address

      # Para os plugins: número do formulário ("2,5" → 2.5; vazio → nil).
      # Rótulos de uma lista do plugin no idioma da tela ({chave → texto} de `texts`).
      def labels(name, source) = source.to_h { |k, _| [ k, text("#{name}.#{k}") ] }

      def number(raw) = raw.to_s.strip.empty? ? nil : Float(raw.to_s.tr(",", "."), exception: false)

      def invalid!(message) = raise(Points::Command::Error.new(:invalid_value, message))

      # Pacote 2: helper que também anda pelo relógio (fim de ciclo, intervalo
      # máximo sem leitura). `HelperTypes.tick` chama `tick` a cada minuto.
      def clocked? = false
      def tick(_point, _now) = nil

      # Ponto de origem (o primeiro de `address.sources`).
      def source(point) = point.site.points.find_by(id: point.address.dig("sources", 0))

      # Leitura usável da origem: número com qualidade boa (nil = fora do ar ou sem valor).
      def reading(src) = src&.quality == "good" && src.value.is_a?(Numeric) ? src.value.to_f : nil

      # Origem numérica do formulário (ou a atual). Trocou de origem = o
      # estado interno recomeça. nil (com erro no ponto) se não serve.
      def numeric_source!(point, form)
        src = point.site.points.find_by(id: form["source"].presence || point.address.dig("sources", 0))
        unless src&.numeric? && src.id != point.id
          point.errors.add(:base, text(:pick_source))
          return
        end

        point.address = point.address.except("state") if point.address.dig("sources", 0) != src.id
        point.address = point.address.merge("sources" => [ src.id ])
        src
      end

      # Estado interno do cálculo (último valor da origem, amostras): fica em
      # `address["state"]`, gravado sem disparar nada; o que a pessoa vê vai para `attrs`.
      def state(point) = point.address["state"].to_h
      def save_state!(point, values) = point.update_column(:address, point.address.merge("state" => values)) # rubocop:disable Rails/SkipsModelValidations
    end
  end
end
