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
                       slots: { name: "Nome do ponto, aparelho, área ou andar, como a pessoa fala", area: "Área ou andar" } },
          en: { denied_only: "I can't control %{names} by voice.", failed: "Couldn't do it: %{names}.", denied: "Not allowed by voice: %{names}.",
                unknown: "I didn't understand and couldn't ask the AI (%{error}). Try \"turn on the living room light\".",
                slots: { name: "Name of the point, device, area or floor, as people say it", area: "Area or floor" } },
          es: { denied_only: "Por voz no puedo controlar %{names}.", failed: "No pude: %{names}.", denied: "Sin permiso por voz: %{names}.",
                unknown: "No entendí y no pude preguntarle a la IA (%{error}). Prueba \"enciende la luz de la sala\".",
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

      # Descrição de um slot (texto da intenção ou o comum da base).
      def slot_text(slot) = text("slots.#{slot}", default: slot.to_s)

      # Ferramenta (formato JSON Schema), para a IA e o MCP.
      def tool
        props = slots.to_h { |s| [ s, { type: numbers.include?(s) ? "number" : "string", description: slot_text(s) } ] }
        { name: key, description: description, parameters: { type: "object", properties: props } }
      end

      def reply(text, points: []) = Reply.new(text: text, intent: key, points: points)

      # Comanda cada ponto com o papel x risco de quem fala e a sombra do
      # local: [feitos, falhas, negados] (nomes).
      def command_all(ctx, points, command, value = nil)
        allowed, denied = points.partition { |p| Assist.can_command?(ctx, p) }
        failed = []
        Shadow.for_site(ctx.site) do
          allowed.each do |p|
            c = Points::Command.call(p, command, value, source: "voice", user: ctx.user)
            failed << p.name if c.error
          rescue Points::Command::Error => e
            failed << "#{p.name} (#{e.message})"
          end
        end
        ok = allowed.map(&:name) - failed.map { |f| f.sub(/ \(.*/, "") }
        [ ok, failed, denied.map(&:name) ]
      end

      # Comando + resposta padrão ("Liguei X. Não consegui: Y. Sem permissão: Z.").
      def run(ctx, points, command, value = nil, done:, **vars)
        return if points.empty?

        ok, failed, denied = command_all(ctx, points, command, value)
        return reply(text(:denied_only, names: Assist.list(denied))) if ok.empty? && failed.empty?

        msg = [ (text(done, names: Assist.list(ok), **vars) if ok.any?), (text(:failed, names: Assist.list(failed)) if failed.any?),
                (text(:denied, names: Assist.list(denied)) if denied.any?) ].compact.join(" ")
        reply(msg, points: points)
      end
    end
  end
end
