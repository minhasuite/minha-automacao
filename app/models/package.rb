# Pacote instalado (Pacote 3, a loja de pacotes declarativos). `manifest` é
# o da versão em uso; `installed` lista o que ele pôs nos registros do local
# ([{type, key, id}]), para atualizar e remover sem tocar no que é do usuário.
class Package < ApplicationRecord
  include Auditable

  acts_as_tenant :tenant

  belongs_to :site

  validates :key, :name, :version, :source_url, presence: true
  validates :key, uniqueness: { scope: :site_id }

  audited_attributes :key, :version

  scope :ordered, -> { order(:name) }

  def items = Array(manifest["items"])
  def ref(type, key) = Array(installed).find { |r| r["type"] == type && r["key"] == key }
end
