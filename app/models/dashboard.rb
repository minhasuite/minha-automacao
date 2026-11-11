# Dashboard do local (ESQUEMA-V1 §4.6 e §6), dirigido pelo servidor: a web e o
# app renderizam o mesmo JSON. `definition` = versão publicada, `draft` =
# rascunho do editor. Publicar e voltar versão gravam um DashboardVersion.
# `auto`: a definição sai do Dashboards::Generator a cada leitura (áreas e
# pontos novos entram sozinhos) até a primeira publicação, que o torna manual.
class Dashboard < ApplicationRecord
  include Auditable

  acts_as_tenant :tenant

  KINDS = { "home" => "Casa", "plant" => "Fábrica", "custom" => "Personalizado" }.freeze
  # Ícones do painel e das visões (os SVG de app/assets/images/icons).
  ICONS = %w[view-boards home light-bulb lightning-bolt sun moon chart-bar switch-horizontal cube office-building
             sparkles bell video-camera vacuum shopping-bag truck clock].freeze

  belongs_to :site
  has_many :versions, -> { order(version: :desc) }, class_name: "DashboardVersion", dependent: nil # cascade no banco
  # Imagens enviadas no editor (planta baixa, papel de parede): o JSON guarda o link.
  has_many_attached :files
  has_many :guest_links, dependent: nil # cascade no banco

  validates :name, presence: true
  validates :kind, inclusion: { in: KINDS.keys }
  validate :icon_known
  validate :roles_known
  validate :definitions_valid

  normalizes :name, with: ->(v) { v.to_s.squish }
  normalizes :icon, with: ->(v) { v.presence }

  audited_attributes :name, :version, :roles, :site_default, :sidebar

  scope :ordered, -> { order(site_default: :desc, position: :asc, created_at: :asc) }

  # Locais sem dashboard ganham o automático (Início + uma view por área).
  def self.ensure_for(site)
    site.dashboards.ordered.to_a.presence || [ site.dashboards.create!(name: site.name, kind: site.kind == "plant" ? "plant" : "home", auto: true, site_default: true) ]
  end

  # Padrão da pessoa no local; senão o padrão do local; senão o primeiro.
  # No app (`app: true`): a escolha da pessoa no app; senão o painel marcado
  # para o app (`app_default`, ex. a versão Mobile importada do HA); senão o da web.
  # `device` (ideia 10, PanelDevice): "neste aparelho abre o painel X" vale antes de tudo.
  def self.default_for(site, user, role, app: false, device: nil)
    list = ensure_for(site).select { |d| d.visible_to?(role) }
    mine = device&.dashboard_for(site, role) and return mine
    if app
      mine = list.find { |d| d.id == user.dashboard_prefs["app:#{site.id}"] }
      return mine || list.find(&:app_default?) || default_for(site, user, role)
    end
    list.find { |d| d.id == user.dashboard_prefs[site.id] } || list.first
  end

  # Painéis marcados "mostrar no menu" que a pessoa vê (barra lateral, como no HA).
  def self.sidebar_for(user)
    sites = Site.visible_to(user).to_a.index_by(&:id)
    where(sidebar: true, site_id: sites.keys).ordered.includes(:site).to_a
      .select { |d| d.visible_to?(sites[d.site_id].role_for(user)) }
  end

  def kind_label = I18n.t("dashboards.kinds.#{kind}", default: kind)
  def icon_name = icon || "view-boards"

  # Cópia manual (fora do menu e do padrão): publicada como versão 1.
  def duplicate!(author: Current.user)
    transaction do
      copy = site.dashboards.create!(name: I18n.t("dashboards.copy_name", name: name), kind: kind, icon: icon, roles: roles, definition: published, position: position + 1)
      copy.publish!(copy.definition, author: author)
      copy
    end
  end
  def visible_to?(role) = roles.empty? || role == "owner" || roles.include?(role)
  # Automático: gerado a cada leitura, com o tema escolhido (primeira configuração) guardado em `definition`.
  # Visão com a marca `auto` (ideia 6) se refaz a cada leitura (Dashboards::AutoViews).
  def published = auto? ? Dashboards::Generator.call(site).merge(definition.to_h.slice("theme")) : Dashboards::AutoViews.expand(definition, site)
  def working_draft = draft ? Dashboards::AutoViews.expand(draft, site) : published
  def draft? = draft.present?

  # Publica o rascunho (ou `new_definition`, da API): vira a versão nova e o
  # dashboard deixa de ser automático.
  def publish!(new_definition = draft, author: Current.user)
    raise ArgumentError, "nada para publicar" if new_definition.blank?

    transaction do
      update!(definition: new_definition, draft: nil, auto: false, version: version + 1)
      versions.create!(tenant_id: tenant_id, version: version, definition: definition, author: author)
    end
  end

  # Voltar versão: a antiga é publicada de novo como a próxima versão.
  def revert!(number, author: Current.user)
    publish!(versions.find_by!(version: number).definition, author: author)
  end

  private

  # Os do conjunto daqui ou os do Home Assistant (`mdi:nome`, painel importado).
  def icon_known
    errors.add(:icon, :inclusion) unless icon.nil? || ICONS.include?(icon) || Mdi.path(icon)
  end

  def roles_known
    errors.add(:roles, :invalid_role) unless roles.all? { |r| SiteMembership::ROLES.include?(r) }
  end

  def definitions_valid
    { definition: (definition unless auto?), draft: draft }.each do |attr, value|
      next if value.nil?

      Dashboards::Schema.errors(value).first(5).each { |e| errors.add(attr, e) }
    end
  end
end
