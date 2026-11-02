# Apelidos (aliases do HA) de ponto e de área (ondaA1, A3): outros nomes
# pelos quais a voz, a busca e as pontes acham o registro.
module Aliasable
  extend ActiveSupport::Concern

  MAX = 10

  included do
    normalizes :aliases, with: ->(list) { Array(list).map { |a| a.to_s.squish }.compact_blank.uniq(&:downcase).first(MAX).map { |a| a.first(60) } }
  end

  def alias_list = aliases.to_a.join(", ")
  def alias_list=(text)
    self.aliases = text.to_s.split(",")
  end

  # Nome e apelidos (para casar com a frase ou a busca).
  def all_names = [ name, *aliases ]
end
