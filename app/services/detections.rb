# Detecção de câmera com IA (integ), genérica: cada plugin (Frigate, Reolink,
# UniFi Protect…) entrega o rótulo da marca e aqui vira um tipo comum. O
# valor do ponto `detection` é {kind, label, score (0–100), zones, id, at,
# clip?}; o gatilho "Câmera detectou" e o "Avisar" com quadro (o plugin dá a
# imagem: `Plugin.snapshot`) só olham isto. Rótulo novo = uma linha em ALIASES.
module Detections
  KINDS = { "person" => "Pessoa", "vehicle" => "Veículo", "animal" => "Animal", "package" => "Encomenda", "face" => "Rosto", "other" => "Outro" }.freeze
  ALIASES = {
    "people" => "person", "car" => "vehicle", "truck" => "vehicle", "bus" => "vehicle", "motorcycle" => "vehicle", "bicycle" => "vehicle",
    "license_plate" => "vehicle", "boat" => "vehicle", "dog" => "animal", "cat" => "animal", "bird" => "animal", "horse" => "animal",
    "dog_cat" => "animal", "pet" => "animal", "animal" => "animal"
  }.freeze

  module_function

  def kind(label) = KINDS.key?(l = label.to_s.downcase) ? l : ALIASES.fetch(l, "other")

  def value(label:, score: nil, zones: nil, id: nil, at: Time.current, **extra)
    { "kind" => kind(label), "label" => label.to_s, "score" => score&.round, "zones" => Array(zones).map(&:to_s).presence,
      "id" => id&.to_s, "at" => at.iso8601 }.merge(extra.stringify_keys).compact
  end

  def text(v)
    return "Sem detecção" unless v.is_a?(Hash)

    [ KINDS.fetch(v["kind"].to_s, v["label"].to_s.humanize), Array(v["zones"]).join(", ").presence, ("#{v['score']}%" if v["score"]) ].compact.join(" · ")
  end

  # Atributos do ponto de detecção de uma câmera (address = o que o driver precisa).
  def point(address) = { "name" => "Detecção", "capability" => "detection", "address" => address }

  # Sensor de "tem pessoa/veículo agora" (verdadeiro enquanto a câmera vê).
  def presence(label, address) = { "name" => "#{KINDS.fetch(kind(label), label.to_s.humanize)} na câmera", "capability" => "motion",
                                   "device_class" => "occupancy", "address" => address }
end
