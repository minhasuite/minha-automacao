# Aparelho que abre um painel (ideia 10): "neste aparelho abre o painel X"
# (o tablet da parede, o celular da cozinha). A web identifica o aparelho pelo
# cookie assinado `ma_device` ("web:<id>"); o app manda o cabeçalho
# `X-MA-Device` com o id da instalação ("app:<install_id>"), que também chega
# às telas do servidor (AppScreen). A regra do aparelho vale por cima do padrão
# da pessoa e do local, se a pessoa vê o painel; sem painel, o aparelho só
# fica nomeado na lista.
class PanelDevice < ApplicationRecord
  include Auditable

  acts_as_tenant :tenant

  KINDS = %w[web app].freeze
  COOKIE = :ma_device
  HEADER = "X-MA-Device".freeze
  KEY = /\A(web|app):[A-Za-z0-9_-]{8,80}\z/

  belongs_to :dashboard, optional: true
  belongs_to :user, optional: true

  validates :name, presence: true, length: { maximum: 60 }
  validates :kind, inclusion: { in: KINDS }
  validates :key, format: { with: KEY }, uniqueness: { scope: :tenant_id }
  validates :view, format: { with: /\A[\w-]{1,100}\z/ }, allow_blank: true

  normalizes :name, with: ->(v) { v.to_s.squish }
  normalizes :view, with: ->(v) { v.presence }
  audited_attributes :name, :dashboard_id, :view

  # A chave do aparelho deste pedido: o cabeçalho do app ou o cookie da web. nil = desconhecido.
  def self.key_for(request, cookies = nil)
    header = request.headers[HEADER].to_s.strip
    return "app:#{header}" if header.match?(/\A[A-Za-z0-9_-]{8,80}\z/)

    id = cookies && cookies.signed[COOKIE].to_s.presence
    "web:#{id}" if id&.match?(/\A[A-Za-z0-9_-]{8,80}\z/)
  end

  def self.current(request, cookies = nil)
    key = key_for(request, cookies) or return
    find_by(key: key)
  end

  # O painel do aparelho no local, se a pessoa (pelo papel) vê.
  def dashboard_for(site, role)
    dashboard if dashboard && dashboard.site_id == site.id && dashboard.visible_to?(role)
  end

  def seen!(user_agent)
    update_columns(last_seen_at: Time.current, user_agent: user_agent.to_s.first(200)) if last_seen_at.nil? || last_seen_at < 5.minutes.ago
  end
end
