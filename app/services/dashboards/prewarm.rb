module Dashboards
  # Pré-aquecimento do painel (`docs/desempenho.md`, "Primeira abertura"): quando um
  # ponto do local muda ou um painel é publicado, um job (com debounce: no máximo um
  # por local a cada DEBOUNCE) resolve o painel padrão de cada pessoa/papel do local,
  # só a visão que abre (`lazy`), e deixa no cache comum (`Dashboards::Cache`, nível
  # `Rails.cache`). A primeira abertura da web/app acha pronto se nada mudou depois;
  # se mudou, resolve só uma visão (o caminho frio também ficou curto).
  #
  # Alvos = `Dashboard.default_for` de cada pessoa ativa (web e app), uma vez por
  # [painel, papel]. Desligado onde o cache está desligado (testes).
  module Prewarm
    DEBOUNCE = 5 # segundos
    MAX_TARGETS = 20

    @due = Concurrent::Map.new

    module_function

    # Avisa que algo do local mudou; enfileira um pré-aquecimento se não há um a caminho.
    def touch(site_id)
      return unless Cache.enabled? && site_id

      now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      last = @due[site_id]
      return if last && now - last < DEBOUNCE

      @due[site_id] = now
      DashboardPrewarmJob.set(wait: DEBOUNCE.seconds).perform_later(site_id)
    rescue StandardError => e # pré-aquecer nunca atrapalha quem gravou o ponto
      Rails.logger.warn("[painel] pré-aquecimento: #{e.message}")
    end

    # [painel, papel] de quem abre o local (padrão da web e do app de cada pessoa).
    def targets(site)
      User.where(disabled_at: nil).find_each.filter_map do |user|
        role = site.role_for(user) or next
        [ Dashboard.default_for(site, user, role), Dashboard.default_for(site, user, role, app: true) ].compact.map { |d| [ d, role ] }
      end.flatten(1).uniq { |d, role| [ d.id, role ] }.first(MAX_TARGETS)
    end

    # Resolve e guarda (Cache.resolved já guarda nos dois níveis). → quantos.
    def run(site)
      list = targets(site)
      list.each { |d, role| Cache.resolved(d, role: role, lazy: true) }
      list.size
    end
  end
end
