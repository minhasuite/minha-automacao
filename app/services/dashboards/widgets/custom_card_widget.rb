module Dashboards
  module Widgets
    # ondaA2 A20: card de terceiros instalado por pacote (Cards), num iframe
    # sandbox com o estado dos pontos escolhidos no formato do HA.
    #
    # P2.5 (decisão de 11/2026): **só web**. Rodar o JS de terceiros num WebView do app
    # pediria o mesmo isolamento do iframe sandbox (origem opaca, CSP, sem o token do app
    # ao alcance) num runtime que não dá essas garantias igual em Android/iOS, mais um
    # plugin nativo e a ponte de estados/comandos; o app mostra um aviso com "abrir na web".
    class CustomCardWidget < Base
      describe type: "custom_card", label: "Card de terceiros", icon: "cube", required: %w[card], params: %w[card config height], binds: true
      texts en: { "label" => "Third-party card", "config" => "config must be a JSON object." },
            es: { "label" => "Tarjeta de terceros", "config" => "config debe ser un objeto JSON." },
            "pt-BR" => { "config" => "config precisa ser um objeto JSON." }

      def self.errors(w) = config(w).is_a?(Hash) ? [] : [ text(:config) ]
      def self.web_only? = true

      def self.config(w)
        c = w["config"]
        c.is_a?(String) ? (c.strip.empty? ? {} : JSON.parse(c)) : (c || {})
      rescue JSON::ParserError
        nil
      end

      def self.data(r, w, binds)
        card = Cards.available(r.site).find { |c| c["ref"] == w["card"] }
        return [ { "missing" => true, "web_only" => true }, [] ] unless card && Cards.read(card["sha"])

        binds.each { |p| r.use(p) }
        [ { "sha" => card["sha"], "integrity" => Cards.integrity(card["sha"]), "element" => card["element"], "name" => card["name"],
            "config" => (config(w) || {}).merge("type" => "custom:#{card['element']}", "entities" => binds.map(&:key)),
            "states" => Cards.states(binds), "height" => w["height"].to_i.clamp(80, 1200).nonzero?, "web_only" => true }, [] ]
      end
    end
  end
end
