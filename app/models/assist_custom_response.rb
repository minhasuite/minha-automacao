# Resposta personalizada da voz (P3): o texto que a casa fala no lugar do
# padrão de uma intenção (`Assist::INTENTS`), por local e idioma (vazio =
# qualquer um). `intent` = chave da intenção ou "*" (vale para todas, nos
# textos comuns da base como `denied` e `failed`); `text_key` = chave do
# texto da intenção (`Intent.text`). `{names}` ou `%{names}` trocam pelos
# mesmos valores da resposta padrão. Lida pelo `Assist::Intent.text` com o
# local da conversa (`Assist.with_site`).
class AssistCustomResponse < ApplicationRecord
  include Auditable

  acts_as_tenant :tenant

  ANY = "*".freeze

  belongs_to :site

  normalizes :language, with: ->(v) { v.to_s.presence_in(Assist::LANGUAGES) }
  normalizes :text, with: ->(v) { v.to_s.squish }

  validates :text, presence: true, length: { maximum: 300 }
  validates :text_key, uniqueness: { scope: %i[site_id intent language] }
  validate :key_exists

  audited_attributes :intent, :text_key, :language, :text

  # Chave do formulário/API num campo só: "scene.done".
  def ref = ("#{intent}.#{text_key}" if intent && text_key)
  def ref=(value)
    self.intent, self.text_key = value.to_s.split(".", 2)
  end

  # Texto com as variáveis (`{x}` ou `%{x}`); a que faltar some.
  def render(vars)
    text.gsub(/%?\{(\w+)\}/) { vars.fetch(::Regexp.last_match(1).to_sym) { vars[::Regexp.last_match(1)] }.to_s }.squish
  end

  # Textos que dá para trocar: [intenção, chave, texto padrão no idioma] das
  # intenções do registro (sem descrição nem slots) e os comuns da base ("*").
  def self.choices
    own = Assist.intents.flat_map { |i| keys_of(i).map { |k| [ i.key, k, i.text(k) ] } }
    base = keys_of(Assist::Intent).map { |k| [ ANY, k, Assist::Intent.text(k) ] }
    base + own
  end

  def self.keys_of(klass) = (klass.texts["pt-BR"] || {}).keys.reject { |k| k == "description" || k.start_with?("slots.") }

  private

  def key_exists
    errors.add(:text_key, :inclusion) unless self.class.choices.any? { |i, k, _| i == intent && k == text_key }
  end
end
