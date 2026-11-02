module Automations
  module TriggerTypes
    # Câmera detectou (integ): pessoa, veículo, animal… num ponto `detection`
    # de qualquer marca (Detections), com zona e confiança mínima opcionais.
    # Cada detecção nova dispara, mesmo repetida (Point::REPEATING).
    class DetectionTrigger < Base
      describe key: "detection", label: "Câmera detectou", defaults: { "kind" => "person" },
               fields: [ f("point", :point, "Detecção da câmera", required: true),
                         f("kind", :select, "O quê", required: true, options: { "any" => "Qualquer coisa" }.merge(Detections::KINDS)),
                         f("zone", :text, "Só na zona (opcional)"), f("min_score", :number, "Confiança mínima em % (opcional)") ]

      def self.fires_on_change?(t, value, _was) = holds?(t, value)

      def self.holds?(t, v)
        v.is_a?(Hash) && (t["kind"].in?([ nil, "", "any" ]) || v["kind"] == t["kind"]) &&
          (t["zone"].blank? || Array(v["zones"]).any? { |z| z.to_s.casecmp?(t["zone"].to_s.strip) }) &&
          (t["min_score"].blank? || v["score"].to_f >= t["min_score"].to_f)
      end

      def self.title(t) = "Câmera detectou #{t['kind'] == 'any' ? 'algo' : Detections::KINDS.fetch(t['kind'].to_s, '').downcase}".strip
    end
  end
end
