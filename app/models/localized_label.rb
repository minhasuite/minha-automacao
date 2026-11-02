# Rótulo de constante (Site::KINDS, Device::SITUATIONS, papéis...) no idioma
# da tela, lido na hora do uso: `KINDS = LocalizedLabel.for("labels.site_kinds",
# %w[home store])`, texto em config/locales/home.*.yml. Age como a String
# traduzida (to_s, to_str, downcase, ==, <=>, JSON), então quem já usava
# `KINDS.invert`, `fetch` ou `.downcase` continua igual e passa a traduzir.
class LocalizedLabel < BasicObject
  def self.for(scope, keys) = keys.to_h { |k| [ k, new("#{scope}.#{k}") ] }.freeze

  def initialize(key) = @key = key

  def to_s = ::I18n.t(@key)
  alias to_str to_s
  def inspect = to_s.inspect
  def ==(other) = to_s == other.to_s
  def as_json(*) = to_s
  def to_json(*) = to_s.to_json
  def respond_to?(name, all = false) = %i[to_s to_str as_json to_json].include?(name.to_sym) || to_s.respond_to?(name, all)
  def method_missing(name, ...) = to_s.public_send(name, ...)
  def respond_to_missing?(name, all = false) = to_s.respond_to?(name, all)
end
