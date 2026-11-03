module Dashboards
  module Widgets
    # Gás e água (ondaB2 B12): consumo e custo de medidores de volume (m³ ou
    # L acumulados), com período, tarifa por m³, meta e comparação; o mesmo
    # card do Consumo e custo, pelo `Dashboards::Meter`.
    class UtilityWidget < Base
      KINDS = { "gas" => [ "fire", "#f97316" ], "water" => [ "beaker", "#0ea5e9" ] }.freeze
      describe type: "utility", label: "Gás e água", icon: "beaker", required: %w[binds], params: %w[kind period tariff tariff_point goal compare], binds: true
      texts en: { label: "Gas and water", gas: "Gas", water: "Water", pick: "Pick a gas or water meter (m³ or L).", bad_kind: "kind is gas or water" },
            es: { label: "Gas y agua", gas: "Gas", water: "Agua", pick: "Elige un medidor de gas o agua (m³ o L).", bad_kind: "kind es gas o water" },
            "pt-BR" => { gas: "Gás", water: "Água", pick: "Escolha um medidor de gás ou água (m³ ou L).", bad_kind: "kind é gas ou water" }

      def self.errors(w) = EnergyWidget.errors(w) + (w.key?("kind") && !KINDS.key?(w["kind"]) ? [ text(:bad_kind) ] : [])
      def self.attrs(p, site = nil) = EnergyWidget.attrs(p, site).merge("kind" => p[:kind].presence_in(KINDS.keys) || "water")
      def self.form = [ EnergyWidget.form, "web/dashboards/widget_forms/utility" ]
      def self.partial = EnergyWidget.partial

      def self.data(r, w, binds)
        tariff = r.use(r.point(w["tariff_point"]))
        kind = KINDS.key?(w["kind"]) ? w["kind"] : (binds.first&.device_class == "gas" ? "gas" : "water")
        ico, tone = KINDS[kind]
        [ Meter.new(w, binds, r.site, tariff_point: tariff).call.merge("unit" => "m³", "kind" => kind, "title" => text(kind), "icon" => ico, "tone" => tone,
                                                                         "missing_text" => text(:pick)), [ tariff ].compact ]
      end
    end
  end
end
