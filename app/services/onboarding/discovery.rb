module Onboarding
  # Descoberta de uma vez (primeira configuração): todos os plugins com
  # `discovers?` em paralelo, cada um com o seu tempo; plugin que falha ou
  # demora fica de fora. Só lista: nada é cadastrado aqui.
  module Discovery
    WAIT_S = 6

    module_function

    # → [{"plugin", "title", "icon", "name", "host", "port", "txt", "added"}]
    def call(site)
      known = site.integrations.filter_map { |i| i.settings["host"] }.to_set
      threads = Integrations.plugins.select(&:discovers?).map { |p| [ p, Thread.new { safe(p) } ] }
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + WAIT_S
      threads.flat_map do |plugin, t|
        list = t.join([ deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC), 0 ].max)&.value
        t.kill unless list
        Array(list).map do |e|
          e.merge("plugin" => plugin.key, "title" => plugin.title, "icon" => plugin.icon,
                  "name" => e.dig("txt", "friendly_name").presence || e.dig("txt", "fn").presence || e["name"], "added" => known.include?(e["host"]))
        end
      end
    end

    def safe(plugin)
      Array(plugin.discover)
    rescue StandardError => e
      Rails.logger.info("[descoberta] #{plugin.key}: #{e.message}")
      []
    end
  end
end
