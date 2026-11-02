module Assist
  module Intents
    # "Deixa pra lá" (HassNevermind): não faz nada e não responde.
    class Nevermind < Intent
      describe key: "nevermind", tool: false,
               description: "Desiste do pedido sem fazer nada.",
               sentences: { "pt-BR" => [ "(deixa|deixe) (pra|para) la", "(esquece|esqueca|esquecer)", "(nada|cancela|cancelar|deixa)" ],
                            "en" => [ "never mind", "nevermind", "forget it", "(cancel|nothing)" ],
                            "es" => [ "(olvidalo|olvida|olvidar|dejalo|dejalo ya)", "(nada|cancela|cancelar)" ] }
      texts en: { description: "Drops the request without doing anything." },
            es: { description: "Abandona el pedido sin hacer nada." }

      def self.handle(_ctx, _slots) = reply("")
    end
  end
end
