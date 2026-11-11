module Dashboards
  # Assistente do painel (ideia 8 da proposta de personalização): escolhe os
  # cômodos e o estilo e sai um painel pronto. Por cima do que já existe:
  # Início do painel automático (`Generator`), uma visão automática por
  # cômodo (`AutoViews`, que se refaz quando entra aparelho novo, até o dono
  # congelar) e o tema (`Themes`). Estilo:
  #
  # - `columns`: o cômodo arrumado pelas regras do local (`RoomLayout`: selos,
  #   ações, cenas e mídia em colunas);
  # - `devices`: o cômodo como no automático (uma seção por aparelho).
  #
  # Usado pela primeira configuração (passo do painel) e pelo botão
  # "Assistente" em Painéis.
  module Wizard
    LAYOUTS = %w[columns devices].freeze

    module_function

    def layouts = LAYOUTS.map { |k| [ k, I18n.t("arrange.wizard.layouts.#{k}"), I18n.t("arrange.wizard.layouts.#{k}_hint") ] }
    def areas(site) = site.areas.order(:position, :name).reject(&:floor?)

    # → definição pronta e válida (as visões automáticas já refeitas).
    def build(site, area_ids:, theme: nil, layout: "columns")
      all = areas(site)
      chosen = all.select { |a| Array(area_ids).map(&:to_s).include?(a.id.to_s) }
      home = { "id" => "home", "title" => I18n.t("dashboards.gen.home"), "icon" => "home",
               "auto" => { "home" => true, "areas" => (chosen.map(&:id) if chosen.size < all.size) }.compact, "sections" => [] }
      defn = { "schema_version" => Schema::VERSION, "views" => [ home ] }
      chosen.each do |a|
        v = AutoViews.new_area_view(defn, a)
        v["auto"]["arrange"] = false if layout == "devices"
        defn["views"] << v
      end
      defn["theme"] = { "key" => theme.key } if (theme = Themes[theme])
      defn = AutoViews.expand(defn, site)
      errors = Schema.errors(defn)
      raise ArgumentError, errors.first(3).to_sentence if errors.any?

      defn
    end

    # Painel novo, publicado (versão 1).
    def create!(site, name:, author:, **opts)
      defn = build(site, **opts)
      Dashboard.transaction do
        d = site.dashboards.create!(name: name.to_s.squish.presence || I18n.t("arrange.wizard.default_name"),
                                    kind: site.kind == "plant" ? "plant" : "home", definition: defn)
        d.publish!(defn, author: author)
        d
      end
    end
  end
end
