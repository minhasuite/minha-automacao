# Interruptor editável no admin. Sem linha = ligado (flag serve para DESLIGAR).
class FeatureFlag < ApplicationRecord
  CACHE_KEY = "feature_flags/map".freeze

  KNOWN = {
    "push" => "Nenhum push sai (as notificações in-app continuam)."
  }.freeze

  validates :key, presence: true, uniqueness: true, inclusion: { in: KNOWN.keys }

  after_commit { Rails.cache.delete(CACHE_KEY) }

  def self.on?(key) = map.fetch(key.to_s, true)

  def self.map
    Rails.cache.fetch(CACHE_KEY) { all.to_h { |f| [ f.key, f.enabled ] } }
  rescue ActiveRecord::StatementInvalid
    {}
  end

  def self.seed_defaults! = KNOWN.each_key { |key| find_or_create_by!(key: key) }
end
