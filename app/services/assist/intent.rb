module Assist
  # Base das intenções (plugins de Assist::INTENTS). Cada uma se descreve:
  #   describe key:, description:, sentences: {"pt-BR" => [...], "en" => [...], "es" => [...]},
  #            slots: {"name" => "o que é"}, numbers: %w[brightness], tool: true
  # e implementa `handle(ctx, slots)` → Reply ou nil (não é comigo: a próxima
  # tenta). `tool: true` = vira ferramenta da IA (Assist::Llm) e do servidor
  # MCP, com os slots como parâmetros e a mesma checagem de papel x risco.
  # Respostas por `text(:chave)` nos três idiomas (PluginTexts).
  class Intent
    extend PluginTexts
    translates :description

    texts "pt-BR" => { denied_only: "Por voz não posso comandar %{names}.", failed: "Não consegui: %{names}.", denied: "Sem permissão por voz: %{names}.",
                       unknown: "Não entendi e não consegui perguntar à IA (%{error}). Tente \"ligar a luz da sala\".",
                       not_understood: "Não entendi \"%{heard}\". Tente \"ligar a luz da sala\" ou \"a porta da cozinha está aberta?\".",
                       offline: "Estou sem internet: entendo só os comandos da casa, como \"ligar a luz da sala\". Não entendi \"%{heard}\".",
                       slots: { name: "Nome do ponto, aparelho, área ou andar, como a pessoa fala", area: "Área ou andar" } },
          en: { denied_only: "I can't control %{names} by voice.", failed: "Couldn't do it: %{names}.", denied: "Not allowed by voice: %{names}.",
                unknown: "I didn't understand and couldn't ask the AI (%{error}). Try \"turn on the living room light\".",
                not_understood: "I didn't understand \"%{heard}\". Try \"turn on the living room light\" or \"is the kitchen door open?\".",
                offline: "I'm offline: I only understand house commands, like \"turn on the living room light\". I didn't understand \"%{heard}\".",
                slots: { name: "Name of the point, device, area or floor, as people say it", area: "Area or floor" } },
          es: { denied_only: "Por voz no puedo controlar %{names}.", failed: "No pude: %{names}.", denied: "Sin permiso por voz: %{names}.",
                unknown: "No entendí y no pude preguntarle a la IA (%{error}). Prueba \"enciende la luz de la sala\".",
                not_understood: "No entendí \"%{heard}\". Prueba \"enciende la luz de la sala\" o \"¿está abierta la puerta de la cocina?\".",
                offline: "Estoy sin internet: solo entiendo los comandos de la casa, como \"enciende la luz de la sala\". No entendí \"%{heard}\".",
                slots: { name: "Nombre del punto, aparato, área o piso, como lo dice la persona", area: "Área o piso" } }

    class << self
      attr_reader :key

      def describe(key:, description:, sentences: {}, slots: [], numbers: [], tool: true)
        @key = key
        @description = description
        @sentences = sentences.transform_keys(&:to_s)
        @slots = slots.map(&:to_s)
        @numbers = numbers.map(&:to_s)
        @tool = tool
      end

      def sentences(language = nil) = language ? Array(@sentences&.dig(language.to_s)) : (@sentences || {})
      def slots = @slots || []
      def numbers = @numbers || []
      def tool? = @tool == true && key.present?

      # Slots da frase (Hash) ou nil.
      def match(ctx, norm)
        sentences(ctx.language).each do |s|
          found = Sentences.match(s, norm, numbers: numbers) and return found
        end
        nil
      end

      def handle(_ctx, _slots) = nil

      # voz-offline: os slots fazem sentido para esta intenção? Usado pelo
      # reconhecer sem executar (teste de frase e aba Testar), que não pode
      # chamar o `handle`: a frase "ligar a luz" casa com "{direction} {name}"
      # do brilho, mas "ligar" não é direção. Padrão: sim.
      def accepts?(_ctx, _slots) = true

      # P3: resposta personalizada do local da conversa (`AssistCustomResponse`,
      # pela intenção ou "*" e pelo idioma ou qualquer um) no lugar da padrão.
      def text(key, default: nil, **vars)
        custom = Assist.custom_response(self.key || AssistCustomResponse::ANY, key.to_s)
        custom ? custom.render(vars) : super
      end

      # Descrição de um slot (texto da intenção ou o comum da base).
      def slot_text(slot) = text("slots.#{slot}", default: slot.to_s)

      # Ferramenta (formato JSON Schema), para a IA e o MCP.
      def tool
        props = slots.to_h { |s| [ s, { type: numbers.include?(s) ? "number" : "string", description: slot_text(s) } ] }
        { name: key, description: description, parameters: { type: "object", properties: props } }
      end

      # O aparelho, quando o ponto é uma parte dele (Brilho → Lâmpada).
      def device_label = ->(p) { p.device&.name.presence || p.name }

      def reply(text, points: []) = Reply.new(text: text, intent: key, points: points)

      # Comanda cada ponto com o papel x risco de quem fala e a sombra do
      # local: [feitos, falhas, negados] (nomes).
      # `label`: como o ponto aparece na resposta (padrão: o nome; brilho e ajuste usam o aparelho).
      def command_all(ctx, points, command, value = nil, label: :name.to_proc)
        allowed, denied = points.partition { |p| Assist.can_command?(ctx, p) }
        failed = []
        Shadow.for_site(ctx.site) do
          allowed.each do |p|
            c = Points::Command.call(p, command, value, source: "voice", user: ctx.user)
            failed << label.call(p) if c.error
          rescue Points::Command::Error => e
            failed << "#{label.call(p)} (#{e.message})"
          end
        end
        ok = allowed.map { |p| label.call(p) } - failed.map { |f| f.sub(/ \(.*/, "") }
        [ ok.uniq, failed, denied.map { |p| label.call(p) }.uniq ]
      end

      # Comando + resposta padrão ("Liguei X. Não consegui: Y. Sem permissão: Z.").
      def run(ctx, points, command, value = nil, done:, label: :name.to_proc, **vars)
        return if points.empty?

        ok, failed, denied = command_all(ctx, points, command, value, label: label)
        return reply(text(:denied_only, names: Assist.list(denied))) if ok.empty? && failed.empty?

        msg = [ (text(done, names: Assist.list(ok), **vars) if ok.any?), (text(:failed, names: Assist.list(failed)) if failed.any?),
                (text(:denied, names: Assist.list(denied)) if denied.any?) ].compact.join(" ")
        reply(msg, points: points)
      end
    end
  end
end
