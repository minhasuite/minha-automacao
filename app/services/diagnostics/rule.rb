module Diagnostics
  # Uma regra do diagnóstico. Subclasse:
  #
  #   class SemArea < Rule
  #     describe key: "no_area", label: "Sem área", description: "...", subject: :device, severity: "info"
  #     texts "pt-BR" => { reason: "..." }, en: {...}, es: {...}
  #     def self.applies?(device, ctx) = device.area_id.nil?
  #     def self.fixes(_device, _ctx) = %w[set_area]
  #   end
  #
  # `finding` devolve o achado (motivo provável, severidade, detalhe e os
  # reparos oferecidos); o padrão usa o texto `reason` e a severidade do
  # describe. `fixes` = chaves de `Diagnostics::FIXES`; só entram as que o
  # reparo diz que servem para aquele achado (`Fix.available?`).
  class Rule
    extend PluginTexts
    translates :label, :description

    class << self
      attr_reader :key, :subject, :severity, :icon

      def describe(key:, label:, description:, subject: :device, severity: "warn", icon: "exclamation-circle", notify: false)
        raise ArgumentError, "severidade inválida: #{severity}" unless SEVERITIES.include?(severity)

        @key = key
        @label = label
        @description = description
        @subject = subject
        @severity = severity
        @icon = icon
        @notify = notify
      end

      # Avisa (notificação semanal) quando o local liga o aviso (bateria).
      def notify? = @notify == true

      def applies?(_subject, _ctx) = raise(NotImplementedError)
      def fixes(_subject, _ctx) = []

      def finding(subject, ctx, severity: self.severity, reason: text(:reason), detail: nil, since: nil)
        f = Finding.new(rule: self, subject: subject, device: device_of(subject), severity: severity, reason: reason, detail: detail,
                        fixes: [], since: since, snoozed_until: nil)
        f.with(fixes: fixes(subject, ctx).select { |k| Diagnostics.fix(k)&.available?(f, ctx) })
      end

      def device_of(subject)
        return subject if subject.is_a?(Device)

        subject.is_a?(Point) ? subject.device : nil
      end

      # "há 3 h" / "há 2 dias" (texto comum da base).
      def ago(time, now)
        return nil unless time

        h = ((now - time) / 3600).floor
        h >= 48 ? Rule.text(:days_ago, n: h / 24) : Rule.text(:hours_ago, n: [ h, 1 ].max)
      end

      def num(v) = ActiveSupport::NumberHelper.number_to_rounded(v.to_f, precision: 1, strip_insignificant_zeros: true, delimiter: "")
    end

    texts "pt-BR" => { hours_ago: "há %{n} h", days_ago: "há %{n} dias" },
          en: { hours_ago: "%{n} h ago", days_ago: "%{n} days ago" },
          es: { hours_ago: "hace %{n} h", days_ago: "hace %{n} días" }
  end
end
