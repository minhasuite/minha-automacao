module Dashboards
  # Selo de "dado velho" (ideia 22 da proposta de personalização): o widget
  # cujo ponto não manda leitura (`reported_at`) há mais que o limite ganha
  # `stale` ({since, text, point_ids}) no JSON resolvido; a web e o app só
  # desenham o selo. O limite, em minutos, vem do widget (`stale_after_min`; 0
  # desliga) ou do local por tipo (Configurações → Painéis → Padrões:
  # `settings.dashboard_defaults.stale_after_min`, chave = `device_class`, a
  # capacidade ou `default`). Ponto sem sinal já mostra a qualidade; só o "bom"
  # parado entra aqui. O padrão vale para medidas que reportam sozinhas
  # (temperatura e umidade); sensor que só fala quando muda (porta, movimento)
  # ficaria "velho" sem estar.
  module Staleness
    DEFAULTS = { "temperature" => 240, "humidity" => 240 }.freeze
    MAX_MIN = 60 * 24 * 30

    module_function

    def limits(site)
      saved = site.settings.to_h.dig("dashboard_defaults", "stale_after_min")
      saved.is_a?(Hash) ? saved : DEFAULTS
    end

    def limit(limits, point) = [ point.device_class, point.capability, "default" ].compact.lazy.filter_map { |k| limits[k.to_s] }.first

    # r = Resolver; points = os pontos do widget (bind/binds).
    def for(r, w, points, now: Time.current)
      own = w["stale_after_min"]
      return nil if own == 0 || points.empty?

      old = points.select do |p|
        min = own || limit(r.stale_limits, p)
        at = p.reported_at || p.changed_at
        min.to_i.positive? && p.quality == "good" && at && at < now - min.to_i.minutes
      end
      return nil if old.empty?

      since = old.filter_map { |p| p.reported_at || p.changed_at }.min
      { "since" => since.iso8601, "point_ids" => old.map(&:id),
        "text" => I18n.t("dashboards.stale.badge", ago: ApplicationController.helpers.ago_text(since)) }
    end

    # Formulário (Configurações → Padrões): linhas {key, min} → mapa; vazio = sem limite.
    def from_form(rows)
      rows = rows.respond_to?(:values) ? rows.values : Array(rows)
      rows.to_h { |row| [ row.to_h.stringify_keys["key"].to_s.strip, row.to_h.stringify_keys["min"].to_i ] }
          .select { |k, v| k.match?(/\A[a-z0-9_]{1,40}\z/) && v.between?(1, MAX_MIN) }
    end
  end
end
