module Health
  module Checks
    # Saúde dos aparelhos (Diagnostics): por local, quantos achados contam
    # (sem os silenciados e sem os só informativos) e o link para a tela com o
    # motivo e os reparos. Não avisa sozinha: a bateria baixa tem aviso próprio
    # (`Diagnostics.notify!`) e o aparelho sem sinal já avisa pela "Aparelhos e pontos".
    class DeviceHealth < Check
      describe key: "device_health", label: "Saúde dos aparelhos", icon: "chip", alerts: false
      texts "pt-BR" => { title: "%{site}: diagnóstico dos aparelhos", clean: "Nada a reparar", open: "Abrir a saúde dos aparelhos",
                         count: "%{n} problema(s): %{list}", snoozed: "%{n} silenciado(s)" },
            en: { label: "Device health", title: "%{site}: device diagnosis", clean: "Nothing to fix", open: "Open device health",
                  count: "%{n} problem(s): %{list}", snoozed: "%{n} snoozed" },
            es: { label: "Salud de los dispositivos", title: "%{site}: diagnóstico de los dispositivos", clean: "Nada que reparar",
                  open: "Abrir la salud de los dispositivos", count: "%{n} problema(s): %{list}", snoozed: "%{n} silenciado(s)" }

      def self.items(_tenant)
        Site.order(:name).map do |site|
          all = Diagnostics.run(site)
          open = Diagnostics.problems(all)
          snoozed = all.count(&:snoozed?)
          list = open.group_by(&:rule).map { |r, fs| "#{fs.size} #{r.label.downcase}" }.join(", ")
          detail = [ (open.empty? ? text(:clean) : text(:count, n: open.size, list: list)), (text(:snoozed, n: snoozed) if snoozed.positive?) ].compact.join(" · ")
          item(key: site.id, status: open.empty? ? "ok" : Diagnostics::HEALTH.fetch(Diagnostics.worst(open)), title: text(:title, site: site.name), detail: detail,
               fix: ({ label: text(:open), url: Rails.application.routes.url_helpers.device_health_path(site_id: site.id) } if open.any?))
        end
      end
    end
  end
end
