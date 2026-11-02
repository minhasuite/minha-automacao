module Automations
  module TriggerTypes
    # Frase dita ao assistente (ondaB1, B2; o gatilho `conversation` do HA):
    # uma frase-modelo por linha no formato do HA ([opcional], (a|b), {slot};
    # Assist::Sentences), em qualquer idioma. Quem casa é o Assist (intenção
    # Assist::Intents::Conversation, antes das nativas): dispara a automação
    # e responde a `response`, com {slot} trocado pelo que foi dito. No texto:
    # {{ trigger.sentence }} e {{ trigger.slots.nome }}.
    class ConversationTrigger < Base
      describe key: "conversation", label: "Frase dita ao assistente",
               fields: [ f("command", :template, "Frases (uma por linha; [opcional], (a|b), {slot})", required: true,
                           en: "Sentences (one per line; [optional], (a|b), {slot})", es: "Frases (una por línea; [opcional], (a|b), {slot})"),
                         f("response", :text, "Resposta (pode usar {slot}; vazio = \"Feito.\")", en: "Response (can use {slot}; empty = \"Done.\")",
                           es: "Respuesta (puede usar {slot}; vacío = \"Hecho.\")") ]
      texts "pt-BR" => { title: "Frase \"%{sentence}\"", bad: "frase %{n}: %{error}" },
            en: { label: "Sentence said to the assistant", title: "Sentence \"%{sentence}\"", bad: "sentence %{n}: %{error}" },
            es: { label: "Frase dicha al asistente", title: "Frase \"%{sentence}\"", bad: "frase %{n}: %{error}" }

      MAX = 20

      def self.sentences(t) = (t["command"].is_a?(Array) ? t["command"] : t["command"].to_s.lines).map(&:strip).compact_blank.first(MAX)

      def self.rules(node)
        list = sentences(node)
        return [ Assist::Sentences.error("") ] if list.empty?

        list.each_with_index.filter_map { |s, i| (e = Assist::Sentences.error(s)) && text(:bad, n: i + 1, error: e) }
      end

      def self.title(t) = text(:title, sentence: sentences(t).first.to_s.truncate(60))

      # Automações ligadas do local com este gatilho → [automação, gatilho, slots] da primeira frase que casa.
      def self.find(site, norm)
        Automation.where(site: site, enabled: true).where("definition->'triggers' @> ?", [ { type: key } ].to_json).find_each do |a|
          next unless a.published?

          Array(a.definition["triggers"]).each do |t|
            next unless t["type"] == key && t["enabled"] != false

            sentences(t).each { |s| (slots = Assist::Sentences.match(s, norm)) and return [ a, t, slots ] }
          end
        end
        nil
      end
    end
  end
end
