module Health
  module Checks
    # Desempenho (Performance 8): as telas e os widgets mais lentos das últimas
    # 24 h (tempo médio e pior), pela amostra do `Perf`. Só informa (atenção
    # quando a média passa do limite); não vira aviso.
    class Performance < Check
      describe key: "performance", label: "Desempenho", icon: "lightning-bolt", alerts: false
      texts "pt-BR" => { screens: "Telas", widgets: "Widgets do painel", empty: "Sem medição ainda", detail: "média %{avg} ms · pior %{max} ms · %{n} vezes" },
            en: { label: "Performance", screens: "Screens", widgets: "Dashboard widgets", empty: "No measurements yet", detail: "average %{avg} ms · worst %{max} ms · %{n} times" },
            es: { label: "Rendimiento", screens: "Pantallas", widgets: "Widgets del panel", empty: "Sin mediciones todavía", detail: "promedio %{avg} ms · peor %{max} ms · %{n} veces" }
      TOP = 5
      # Média acima disso = atenção (ms).
      WARN = { "screen" => 1000, "widget" => 300 }.freeze
      # Poucas vezes não dizem nada sobre a média.
      MIN_COUNT = 3

      def self.items(_tenant)
        stats = Perf.stats
        return [ item(key: "none", status: "ok", title: text(:empty)) ] if stats.empty?

        %w[screen widget].flat_map do |kind|
          list = stats.select { |s| s[:kind] == kind && s[:count] >= MIN_COUNT }.sort_by { |s| -s[:avg] }.first(TOP)
          list.map do |s|
            item(key: "#{kind}:#{s[:key]}", status: s[:avg] > WARN[kind] ? "warn" : "ok", title: "#{text(:"#{kind}s")}: #{display(kind, s[:key])}",
                 detail: text(:detail, avg: s[:avg].round, max: s[:max].round, n: s[:count]))
          end
        end.presence || [ item(key: "none", status: "ok", title: text(:empty)) ]
      end

      def self.display(kind, key)
        return Dashboards::Widgets[key]&.label || key if kind == "widget"

        key.delete_prefix("Web::").delete_prefix("Api::V1::").sub("Controller#", "#")
      end
    end
  end
end
