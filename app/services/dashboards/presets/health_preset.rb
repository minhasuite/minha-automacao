module Dashboards
  module Presets
    # "Saúde da casa" pronta (ideia 23): só consultas sobre o que já existe
    # (`Points::Query`), clicáveis (o selo abre a lista dos pontos com o motivo
    # de cada um, `drill`; a linha abre o ponto). Aparelhos sem sinal, sem
    # leitura recente, baterias baixas, Wi-Fi fraco e, com a integração
    # Sistema, falhas de automação e integrações com erro. Nada é fixo por
    # aparelho: a pessoa ajusta os limites no formulário e depois edita como
    # qualquer painel.
    class HealthPreset < Base
      BATTERY = 20
      WIFI = -75

      describe key: "health", title: "Saúde da casa", icon: "shield-check",
               description: "Aparelhos sem sinal, baterias baixas, Wi-Fi fraco e automações com falha, tudo clicável até o motivo de cada um."
      texts en: { title: "Home health", description: "Devices with no signal, low batteries, weak Wi-Fi and failed automations, each one clickable down to the reason.",
                  fields: { battery: "Low battery below (%)", wifi: "Weak Wi-Fi below (dBm)" }, hints: { battery: "20", wifi: "-75" },
                  gen: { summary: "Summary", offline: "No signal", offline_empty: "Everything is online", stale: "No recent reading", stale_empty: "Everything is up to date",
                         battery: "Low batteries", battery_empty: "No low battery", wifi: "Weak Wi-Fi", wifi_empty: "No weak signal",
                         system: "Automations and integrations", failed: "Failed in 24 h", integrations: "Integrations with errors",
                         b_offline: { zero: "All online", one: "1 no signal", other: "%{count} no signal" },
                         b_battery: { zero: "Batteries OK", one: "1 low battery", other: "%{count} low batteries" },
                         b_wifi: { zero: "Wi-Fi OK", one: "1 weak Wi-Fi", other: "%{count} weak Wi-Fi" } } },
            es: { title: "Salud de la casa", description: "Aparatos sin señal, baterías bajas, Wi-Fi débil y automatizaciones con falla, todo clicable hasta el motivo de cada uno.",
                  fields: { battery: "Batería baja por debajo de (%)", wifi: "Wi-Fi débil por debajo de (dBm)" }, hints: { battery: "20", wifi: "-75" },
                  gen: { summary: "Resumen", offline: "Sin señal", offline_empty: "Todo con señal", stale: "Sin lectura reciente", stale_empty: "Todo al día",
                         battery: "Baterías bajas", battery_empty: "Ninguna batería baja", wifi: "Wi-Fi débil", wifi_empty: "Ninguna señal débil",
                         system: "Automatizaciones e integraciones", failed: "Fallas en 24 h", integrations: "Integraciones con error",
                         b_offline: { zero: "Todo con señal", one: "1 sin señal", other: "%{count} sin señal" },
                         b_battery: { zero: "Baterías bien", one: "1 batería baja", other: "%{count} baterías bajas" },
                         b_wifi: { zero: "Wi-Fi bien", one: "1 Wi-Fi débil", other: "%{count} Wi-Fi débiles" } } },
            "pt-BR" => { gen: { summary: "Resumo", offline: "Sem sinal", offline_empty: "Tudo com sinal", stale: "Sem leitura recente", stale_empty: "Tudo em dia",
                                battery: "Baterias baixas", battery_empty: "Nenhuma bateria baixa", wifi: "Wi-Fi fraco", wifi_empty: "Nenhum sinal fraco",
                                system: "Automações e integrações", failed: "Falhas em 24 h", integrations: "Integrações com erro",
                                b_offline: { zero: "Tudo com sinal", one: "1 sem sinal", other: "%{count} sem sinal" },
                                b_battery: { zero: "Baterias ok", one: "1 bateria baixa", other: "%{count} baterias baixas" },
                                b_wifi: { zero: "Wi-Fi ok", one: "1 Wi-Fi fraco", other: "%{count} Wi-Fi fracos" } } }
      fields [
        { key: "battery", label: "Bateria baixa abaixo de (%)", kind: :number, hint: "20" },
        { key: "wifi", label: "Wi-Fi fraco abaixo de (dBm)", kind: :number, hint: "-75" }
      ]

      OFFLINE = { "quality" => "unavailable,error", "sort" => "name" }.freeze
      STALE = { "quality" => "stale", "sort" => "name" }.freeze

      def self.build(site, form)
        battery = { "device_class" => "battery", "below" => (Widgets::Base.number(form[:battery]) || BATTERY), "sort" => "value" }
        wifi = { "device_class" => "signal_strength", "below" => (Widgets::Base.number(form[:wifi]) || WIFI), "sort" => "value" }
        badges = [ stat("hl-b-offline", OFFLINE, "b_offline", "status-offline"), stat("hl-b-battery", battery, "b_battery", "battery"),
                   stat("hl-b-wifi", wifi, "b_wifi", "mdi:wifi") ]
        sections = [
          section("hl-offline", text("gen.offline"), "status-offline", [ list("hl-offline-list", OFFLINE, "offline_empty") ]),
          section("hl-battery", text("gen.battery"), "battery", [ list("hl-battery-list", battery, "battery_empty") ]),
          section("hl-wifi", text("gen.wifi"), "mdi:wifi", [ list("hl-wifi-list", wifi, "wifi_empty") ]),
          section("hl-stale", text("gen.stale"), "clock", [ list("hl-stale-list", STALE, "stale_empty") ])
        ]
        system = system_widgets(site)
        sections << section("hl-system", text("gen.system"), "cog", system) if system.any?
        { "schema_version" => 1,
          "views" => [ { "id" => "saude", "title" => title, "icon" => "shield-check", "badges" => badges, "sections" => sections } ] }
      end

      def self.stat(id, query, labels, icon)
        { "id" => id, "type" => "stat", "query" => query.except("sort"), "aggregate" => "count", "icon" => icon,
          "labels" => %w[zero one other].to_h { |k| [ k, text("gen.#{labels}.#{k}") ] } }
      end

      def self.list(id, query, empty)
        widget(id, "query_list", desktop: 6, query: query, empty_text: text("gen.#{empty}")).merge("span" => { "mobile" => 12, "tablet" => 12, "desktop" => 12 })
      end

      # Pontos da integração Sistema (`SystemPlugin::METRICS`), quando ela existe no local.
      def self.system_widgets(site)
        rows = site.points.joins(:device).where(devices: { driver: "virtual" }).where("devices.external_id LIKE 'system:%'").where("points.address->>'field' IN (?)", %w[failed_24h integrations_error])
                   .pluck(Arel.sql("points.address->>'field'"), :id).to_h
        [ ("failed_24h" if rows["failed_24h"]), ("integrations_error" if rows["integrations_error"]) ].compact.map do |f|
          widget("hl-#{f.tr('_', '-')}", "stat", desktop: 6, bind: rows[f], aggregate: "last", label: text(f == "failed_24h" ? "gen.failed" : "gen.integrations"))
        end
      end
    end
  end
end
