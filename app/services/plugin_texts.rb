# Textos de plugin (integração, helper, widget, gatilho, tema...) nos três
# idiomas, trazidos pelo próprio plugin, sem lista central. O pt-BR vem do
# `describe` (os campos de `translates`) e de `texts "pt-BR" => {...}`; en e
# es de `texts en: {...}, es: {...}`. Chave pode ter ponto ("fields.point").
#
#   class Base
#     extend PluginTexts
#     translates :title, :description   # leitores no idioma da tela
#   end
#   class Clima < Base
#     describe key: "clima", title: "Clima", description: "Previsão do tempo..."
#     texts en: { title: "Weather", description: "Forecast..." },
#           es: { title: "Clima", description: "Pronóstico..." },
#           "pt-BR" => { sem_local: "Defina a localização de %{site}." }
#   end
#   Clima.title            # → "Weather" em en
#   Clima.text(:sem_local, site: "Casa")
#
# Busca no plugin e depois nas classes de cima (texto comum da base), e cai
# no pt-BR. spec/i18n_coverage_spec.rb falha se um texto pt-BR do plugin não
# tiver en e es.
module PluginTexts
  def texts(by_locale = nil)
    @texts ||= {}
    by_locale&.each { |loc, h| (@texts[loc.to_s] ||= {}).merge!(PluginTexts.flat(h)) }
    @texts
  end

  # Campos do describe que têm texto (definido por `translates`).
  def text_fields = []

  def translates(*fields)
    define_singleton_method(:text_fields) { fields }
    fields.each { |f| define_singleton_method(f) { text(f) } }
  end

  # Textos pt-BR deste plugin (só os dele): describe + texts "pt-BR".
  def source_texts
    text_fields.filter_map { |f| v = instance_variable_get("@#{f}") and [ f.to_s, v ] }.to_h
               .select { |_k, v| v.is_a?(String) && v.present? }.merge(texts["pt-BR"] || {})
  end

  def text(key, default: nil, **vars)
    key = key.to_s
    s = lookup(I18n.locale.to_s, key) || lookup("pt-BR", key) || default || key
    vars.any? ? I18n.interpolate(s, vars) : s
  end

  def self.flat(hash, prefix = nil)
    hash.each_with_object({}) do |(k, v), acc|
      name = [ prefix, k ].compact.join(".")
      v.is_a?(Hash) ? acc.merge!(flat(v, name)) : acc[name] = v
    end
  end

  private

  def lookup(locale, key)
    ancestors.each do |c|
      next unless c.is_a?(PluginTexts)

      own = c.instance_variable_get(:@texts)&.dig(locale, key)
      own ||= c.instance_variable_get("@#{key}") if locale == "pt-BR" && c.text_fields.include?(key.to_sym)
      return own if own
    end
    nil
  end
end
