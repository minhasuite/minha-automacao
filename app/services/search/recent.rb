module Search
  # O que sobe na busca de cada pessoa: os itens que ela abriu pela busca
  # (`users.dashboard_prefs["search_recent"]`, até MAX chaves, o último primeiro),
  # os pontos que ela comandou nos últimos dias (tabela `commands`) e os
  # favoritos do painel (`Dashboards::Personal`).
  module Recent
    KEY = "search_recent".freeze
    MAX = 15
    COMMANDED_DAYS = 14

    module_function

    # [{"k" => chave, "t" => título, "i" => ícone, "u" => endereço}], o último primeiro. O retrato
    # (título, ícone, endereço) serve à paleta da web sem consulta; a API relê cada um (`Search.lookup`).
    def entries(user) = Array(user&.dashboard_prefs.to_h[KEY]).select { |e| e.is_a?(Hash) && e["k"].is_a?(String) }.first(MAX)
    def keys(user) = entries(user).pluck("k")

    # Guarda o resultado (já achado e cortado pelo papel) como o mais recente.
    def add!(user, result)
      return unless result&.key

      entry = { "k" => result.key, "t" => result.title.to_s.first(120), "i" => result.icon.to_s, "u" => result.url.to_s }
      prefs = user.dashboard_prefs.to_h
      user.update!(dashboard_prefs: prefs.merge(KEY => ([ entry ] + entries(user).reject { |e| e["k"] == result.key }).first(MAX)))
    end

    # chave → nota extra: aberto pela busca (3 o último, caindo) e ponto comandado (1).
    def boosts(user)
      return {} unless user

      out = {}
      Command.where(user_id: user.id, created_at: COMMANDED_DAYS.days.ago..).distinct.limit(30).pluck(:point_id).each { |id| out["point:#{id}"] = 1 }
      keys(user).each_with_index { |k, i| out[k] = (out[k] || 0) + (3 - (i * 0.15)).round(2) }
      out
    end

    def favorites(user, sites) = sites.flat_map { |s| Dashboards::Personal.ids(user, s) }.to_set { |id| "point:#{id}" }
  end
end
