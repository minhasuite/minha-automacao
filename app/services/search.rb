# Busca global (Ctrl+K, uiweb): fontes por registro, no padrão de
# Integrations::PLUGINS. Fonte nova = classe em app/services/search/ (herda
# de `Source`) + nome em `SOURCES`. Cada fonte devolve resultados (Result) só
# do que a pessoa vê, com a ação rápida quando o papel deixa ("apagar Sala",
# "ativar cena Cinema"); risco/confirmação do ponto viram a pergunta da web.
module Search
  SOURCES = %w[PagesSource PointsSource ScenesSource AreasSource DashboardsSource AutomationsSource].freeze
  LIMIT = 6
  MAX = 24

  # Verbo no começo da frase → ação. "ativar cena X" também tira o "cena".
  VERBS = { "apagar" => "off", "desligar" => "off", "acender" => "on", "ligar" => "on", "alternar" => "toggle",
            "ativar" => "activate", "acionar" => "activate", "executar" => "activate", "rodar" => "activate",
            # en / es (i18n): os verbos de uma palavra só.
            "activate" => "activate", "run" => "activate", "toggle" => "toggle",
            "encender" => "on", "prender" => "on", "activar" => "activate", "ejecutar" => "activate" }.freeze
  FILLER = %w[a o as os da do das dos de cena script luz luzes].freeze

  # `action`: { label:, url:, params:, confirm:, confirm_title: } (POST).
  Result = Data.define(:kind, :title, :subtitle, :icon, :url, :action) do
    def initialize(kind:, title:, subtitle: nil, icon: "search", url: nil, action: nil) = super
  end

  # Quem busca: os locais que vê e o papel em cada um.
  Context = Data.define(:user, :sites, :roles) do
    def self.for(user)
      sites = Site.visible_to(user).order(:name).to_a
      new(user: user, sites: sites, roles: sites.to_h { |s| [ s.id, s.role_for(user) ] })
    end

    def site_ids = sites.map(&:id)
    def allowed?(site_id, action, **) = SiteMembership.allowed?(roles[site_id], action, **)
  end

  Query = Data.define(:text, :verb, :terms) do
    def self.parse(raw)
      words = raw.to_s.squish.first(120).split
      verb = VERBS[Search.norm(words.first.to_s)]
      words = words.drop(1) if verb
      terms = words.map { |w| Search.norm(w) }
      terms -= FILLER if verb && terms.size > 1
      new(text: words.join(" "), verb: verb, terms: terms)
    end

    def blank? = terms.empty?
  end

  module_function

  def sources = SOURCES.map { |n| const_get(n) }
  def norm(s) = I18n.transliterate(s.to_s).downcase

  def call(raw, user)
    q = Query.parse(raw)
    return [] if q.blank?

    ctx = Context.for(user)
    sources.flat_map { |s| s.call(q, ctx).first(LIMIT) }.first(MAX)
  end

  class Source
    class << self
      include Rails.application.routes.url_helpers

      def call(_q, _ctx) = []

      # Todos os termos aparecem no texto (sem acento, sem caixa).
      def match?(q, *texts)
        hay = Search.norm(texts.compact.join(" "))
        q.terms.all? { |t| hay.include?(t) }
      end
    end
  end
end
