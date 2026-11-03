module Dashboards
  module Widgets
    # Imagem (ondaB2 B10; o `picture` do HA): foto enviada no editor ou link
    # seguro, com legenda e, se tiver ponto, o estado por cima (apagada quando
    # desligado). Aceita os gestos (toque leva a uma visão, por exemplo).
    class ImageWidget < Base
      ASPECTS = { "16:9" => "16 / 9", "4:3" => "4 / 3", "3:2" => "3 / 2", "1:1" => "1 / 1", "21:9" => "21 / 9", "3:4" => "3 / 4" }.freeze
      describe type: "image", label: "Imagem", icon: "photograph", required: %w[image], params: %w[image aspect], bind: true
      texts en: { label: "Image", bad_image: "image must be https:// or an uploaded file", bad_aspect: "invalid aspect" },
            es: { label: "Imagen", bad_image: "image debe ser https:// o un archivo enviado", bad_aspect: "aspect no válido" },
            "pt-BR" => { bad_image: "image precisa ser https:// ou um arquivo enviado", bad_aspect: "aspect inválido" }

      def self.gestures? = true
      def self.form = "web/dashboards/widget_forms/cards"

      def self.errors(w)
        e = []
        e << text(:bad_image) unless w["image"].to_s.match?(Themes::IMAGE)
        e << text(:bad_aspect) if w.key?("aspect") && !ASPECTS.key?(w["aspect"])
        e
      end

      def self.data(_r, w, binds)
        [ { "point_ids" => binds.map(&:id), "ratio" => ASPECTS.fetch(w["aspect"] || "16:9"), "image" => (w["image"] if w["image"].to_s.match?(Themes::IMAGE)) }.compact, [] ]
      end
    end
  end
end
