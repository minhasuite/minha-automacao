module Automations
  module TriggerTypes
    # Padrão de tempo (ondaA1, A5; o `time_pattern` do HA): hora, minuto e
    # segundo com "*" (qualquer), "/5" (a cada 5) ou um número. O relógio
    # passa a cada minuto; os segundos (além do 0) disparam pelo
    # AutomationTickJob dentro do minuto.
    class TimePatternTrigger < Base
      PATTERN = %r{\A(?:\*|/\d{1,2}|\d{1,2})\z}
      LIMITS = { "hours" => 23, "minutes" => 59, "seconds" => 59 }.freeze

      describe key: "time_pattern", label: "Padrão de tempo", defaults: { "minutes" => "/5" },
               fields: [ f("hours", :text, "Horas (*, /2 ou 8)", en: "Hours (*, /2 or 8)", es: "Horas (*, /2 u 8)"),
                         f("minutes", :text, "Minutos (*, /5 ou 30)", en: "Minutes (*, /5 or 30)", es: "Minutos (*, /5 o 30)"),
                         f("seconds", :text, "Segundos (*, /15 ou 0)", en: "Seconds (*, /15 or 0)", es: "Segundos (*, /15 o 0)") ]
      texts "pt-BR" => { invalid: "use *, /N ou um número em %{field} (até %{max}).", none: "informe horas, minutos ou segundos.", title: "Padrão %{h}:%{m}:%{s}" },
            en: { label: "Time pattern", invalid: "use *, /N or a number in %{field} (up to %{max}).", none: "enter hours, minutes or seconds.", title: "Pattern %{h}:%{m}:%{s}" },
            es: { label: "Patrón de tiempo", invalid: "usa *, /N o un número en %{field} (hasta %{max}).", none: "indica horas, minutos o segundos.", title: "Patrón %{h}:%{m}:%{s}" }

      def self.clock = true

      def self.rules(node)
        given = LIMITS.keys.select { |k| node[k].present? }
        return [ text(:none) ] if given.empty?

        given.filter_map do |k|
          v = node[k].to_s.strip
          n = v.delete_prefix("/").to_i
          text(:invalid, field: k, max: LIMITS[k]) unless v.match?(PATTERN) && n <= LIMITS[k] && !(v.start_with?("/") && n.zero?)
        end
      end

      # Campo vazio: vale qualquer um se um campo menor foi dado (como no HA:
      # só `minutes: /5` = a cada 5 min de toda hora); senão, o zero.
      def self.match?(spec, x, default)
        v = spec.to_s.strip
        v = default if v.empty?
        return true if v == "*"
        return (x % v.delete_prefix("/").to_i).zero? if v.start_with?("/")

        x == v.to_i
      end

      def self.due?(t, _site, local)
        smaller = ->(*keys) { keys.any? { |k| t[k].present? } ? "*" : "0" }
        match?(t["hours"], local.hour, smaller.call("minutes", "seconds")) && match?(t["minutes"], local.min, smaller.call("seconds"))
      end

      # Segundos do minuto em que dispara (0 = no próprio tick).
      def self.seconds(t) = (0..59).select { |s| match?(t["seconds"], s, "0") }

      def self.title(t) = text(:title, h: t["hours"].presence || "*", m: t["minutes"].presence || "*", s: t["seconds"].presence || "0")
    end
  end
end
