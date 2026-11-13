# Busca global (Ctrl+K na web, campo do Início no app, `GET /api/v1/search`):
# fontes por registro, no padrão de Integrations::PLUGINS. Fonte nova = classe
# em app/services/search/ (herda de `Source`) + nome em `SOURCES`. Cada fonte
# devolve resultados (Result) só do que a pessoa vê, com a ação rápida quando o
# papel deixa ("apagar Sala", "ativar cena Cinema", "executar script X"); risco/
# confirmação do ponto viram a pergunta da web e do app.
#
# Tolerância: sem acento e sem caixa (`norm`), começo de palavra e erro de
# digitação de uma letra (duas em palavra longa) por `Search::Match`. Ordem:
# cada resultado ganha nota (título vale mais; recente, favorito e o que a
# pessoa comandou sobem: `Search::Recent`) e os grupos saem pela melhor nota.
# Ver docs/busca.md.
module Search
  SOURCES = %w[PagesSource SettingsSource PointsSource CamerasSource DevicesSource ScenesSource ScriptsSource AreasSource
               DashboardsSource WidgetsSource DashboardActionsSource AutomationsSource IntegrationsSource].freeze
  LIMIT = 6 # por grupo
  CANDIDATES = 40 # o que cada fonte devolve para a nota escolher os melhores
  MAX = 30

  # Verbo no começo da frase → ação. "ativar cena X" também tira o "cena".
  VERBS = { "apagar" => "off", "desligar" => "off", "acender" => "on", "ligar" => "on", "alternar" => "toggle",
            "ativar" => "activate", "acionar" => "activate", "executar" => "activate", "rodar" => "activate",
            # en / es (i18n): os verbos de uma palavra só.
            "activate" => "activate", "run" => "activate", "toggle" => "toggle",
            "encender" => "on", "prender" => "on", "activar" => "activate", "ejecutar" => "activate" }.freeze
  FILLER = %w[a o as os da do das dos de na no cena script luz luzes].freeze
  # "ligar a luz da sala": a palavra some dos termos, mas a ação prefere as luzes.
  LIGHT_WORDS = %w[luz luzes lampada lampadas].freeze

  # `action`: { label:, url:, params:, confirm:, confirm_title: } (POST da web);
  # `api`: { path:, body: } (o mesmo pela API, relativo a /api/v1); `target`: o que
  # o app abre nativo ({type: point|dashboard, id, site_id, view?, widget_id?});
  # `key`: "tipo:id" (recentes, favoritos e o `kind` da API).
  Result = Data.define(:kind, :title, :subtitle, :icon, :url, :action, :key, :target, :api, :score, :recent, :favorite) do
    def initialize(kind:, title:, subtitle: nil, icon: "search", url: nil, action: nil, key: nil, target: nil, api: nil, score: 0, recent: false, favorite: false) = super
    def type = key.to_s.split(":", 2).first.presence || "other"
  end

  # Quem busca: os locais que vê, o papel em cada um e o que sobe na ordem
  # (`boosts`: chave → nota extra; `favorites`: chaves dos favoritos).
  Context = Data.define(:user, :sites, :roles, :boosts, :favorites) do
    def self.for(user)
      sites = Site.visible_to(user).order(:name).to_a
      new(user: user, sites: sites, roles: sites.to_h { |s| [ s.id, s.role_for(user) ] }, boosts: Recent.boosts(user), favorites: Recent.favorites(user, sites))
    end

    def initialize(user:, sites:, roles:, boosts: {}, favorites: Set.new) = super
    def site_ids = sites.map(&:id)
    def allowed?(site_id, action, **) = SiteMembership.allowed?(roles[site_id], action, **)
  end

  Query = Data.define(:text, :verb, :terms, :light) do
    def self.parse(raw)
      words = raw.to_s.squish.first(120).split
      verb = VERBS[Search.norm(words.first.to_s)]
      words = words.drop(1) if verb
      terms = words.map { |w| Search.norm(w) }
      light = verb.present? && terms.intersect?(LIGHT_WORDS)
      terms -= FILLER + LIGHT_WORDS if verb && (terms - FILLER - LIGHT_WORDS).any?
      new(text: words.join(" "), verb: verb, terms: terms, light: light)
    end

    def initialize(text:, verb:, terms:, light: false) = super
    def blank? = terms.empty?
  end

  module_function

  def sources = SOURCES.map { |n| const_get(n) }
  def norm(s) = I18n.transliterate(s.to_s).downcase

  # Resultados em grupos (mesmo `kind` junto), o melhor grupo primeiro.
  def call(raw, user)
    q = Query.parse(raw)
    return [] if q.blank?

    ctx = Context.for(user)
    groups = sources.each_with_index.filter_map do |s, i|
      list = s.call(q, ctx).map { |r| rank(r, q, ctx) }.sort_by.with_index { |r, j| [ -r.score, j ] }.first(LIMIT)
      [ list, i ] if list.any?
    end
    groups.sort_by { |list, i| [ -list.first.score, i ] }.flat_map(&:first).first(MAX)
  end

  # Nota: o quanto bate (título vale mais) + recente/comandado + favorito.
  def rank(r, q, ctx)
    base = Match.score(q.terms, r.title, r.subtitle) || 0.5 # achou por outro texto (apelido, aparelho)
    base += 2 if norm(r.title).squish == q.terms.join(" ") # o nome inteiro ("Cozinha" → a área Cozinha)
    base += 3 if q.verb && r.action # com verbo, o que a pessoa pode executar vem antes
    fav = r.key && ctx.favorites.include?(r.key)
    boost = r.key ? ctx.boosts.fetch(r.key, 0) : 0
    r.with(score: (base + boost + (fav ? 2 : 0)).round(2), recent: boost.positive?, favorite: fav || false)
  end

  # Item de uma chave ("point:id"), pelo dono do prefixo, já cortado pelo papel; nil = sumiu ou não vê.
  def lookup(key, ctx)
    prefix, id = key.to_s.split(":", 2)
    return if id.blank?

    source = sources.find { |s| s.prefix == prefix } or return
    source.lookup(id, ctx)&.then { |r| r.with(recent: true, favorite: ctx.favorites.include?(r.key)) }
  rescue ActiveRecord::RecordNotFound
    nil
  end

  # Busca vazia: os recentes da pessoa (web: grupo "Recentes" da paleta; app: a lista inicial).
  def recent(user, ctx = Context.for(user)) = Recent.keys(user).filter_map { |k| lookup(k, ctx) }

  class Source
    class << self
      include Rails.application.routes.url_helpers

      def call(_q, _ctx) = []
      # Prefixo da chave dos resultados ("point") e o item de uma chave (recentes). nil = sem recente.
      def prefix = nil
      def lookup(_id, _ctx) = nil

      def match?(q, *texts) = !Match.score(q.terms, *texts).nil?
    end
  end
end
