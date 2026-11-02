module Automations
  module TriggerTypes
    # Câmera detectou (integ): pessoa, veículo, animal… num ponto `detection`
    # de qualquer marca (Detections), com zona e confiança mínima opcionais.
    # Cada detecção nova dispara, mesmo repetida (Point::REPEATING).
    class DetectionTrigger < Base
      describe key: "detection", label: "Câmera detectou", defaults: { "kind" => "person" },
               fields: [ f("point", :point, "Detecção da câmera", required: true, en: "Camera detection", es: "Detección de la cámara"),
                         f("kind", :select, "O quê", required: true, options: -> { { "any" => text(:any) }.merge(Detections::KINDS) }, en: "What", es: "Qué"),
                         f("zone", :text, "Só na zona (opcional)", en: "Only in zone (optional)", es: "Solo en la zona (opcional)"),
                         f("min_score", :number, "Confiança mínima em % (opcional)", en: "Minimum confidence in % (optional)", es: "Confianza mínima en % (opcional)") ]
      texts "pt-BR" => { any: "Qualquer coisa", title: "Câmera detectou %{what}", something: "algo" },
            en: { label: "Camera detected", any: "Anything", title: "Camera detected %{what}", something: "something" },
            es: { label: "La cámara detectó", any: "Cualquier cosa", title: "La cámara detectó %{what}", something: "algo" }

      def self.fires_on_change?(t, value, _was) = holds?(t, value)

      def self.holds?(t, v)
        v.is_a?(Hash) && (t["kind"].in?([ nil, "", "any" ]) || v["kind"] == t["kind"]) &&
          (t["zone"].blank? || Array(v["zones"]).any? { |z| z.to_s.casecmp?(t["zone"].to_s.strip) }) &&
          (t["min_score"].blank? || v["score"].to_f >= t["min_score"].to_f)
      end

      def self.title(t) = text(:title, what: t["kind"] == "any" ? text(:something) : Detections::KINDS.fetch(t["kind"].to_s, "").downcase).strip
    end
  end
end
