# Conta de um provedor de IA da instalação (Lote 2): a chave do próprio
# usuário, cifrada, por provedor (plugin de Ai::PROVIDERS). Configurações → IA.
class AiAccount < ApplicationRecord
  acts_as_tenant :tenant

  encrypts :api_key

  validates :provider, presence: true, uniqueness: { scope: :tenant_id }, inclusion: { in: ->(_) { Ai.providers.map(&:key) } }
  validates :model, length: { maximum: 100 }
  validates :base_url, format: { with: %r{\Ahttps?://[^\s]+\z} }, length: { maximum: 300 }, allow_blank: true

  normalizes :model, :base_url, with: ->(v) { v.to_s.strip.presence }

  def plugin = Ai.provider(provider)
  def client = plugin.new(api_key: api_key, base_url: (base_url if plugin.custom_url?))
  def model_or_default = model.presence || plugin.default_model
  def usable? = enabled && plugin.present? && (api_key.present? || !plugin.key_required?)

  def self.usable = all.select(&:usable?)

  # Provedor pedido (chave) ou o padrão da instalação, ou o primeiro que serve.
  def self.pick(key = nil, default: nil)
    list = usable
    return list.find { |a| a.provider == key.to_s } if key.present?

    list.find { |a| a.provider == default.to_s } || list.first
  end
end
