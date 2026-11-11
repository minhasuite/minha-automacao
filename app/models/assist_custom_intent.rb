# Intenção personalizada da voz (P3): o dono cadastra frases-modelo (formato
# do HA: `[opcional]`, `(a|b)`, `{slot}`; `Assist::Sentences`) que acionam uma
# cena ou rodam um script do local, num idioma (vazio = qualquer um), com a
# resposta da casa (`{slot}` trocado; vazio = a padrão). Reconhecida pela
# intenção `Assist::Intents::Custom`, antes das nativas. Crítico nunca: a
# validação recusa cena ou script crítico e a execução confere de novo
# (papel x risco de quem fala, sombra do local).
class AssistCustomIntent < ApplicationRecord
  include Auditable

  acts_as_tenant :tenant

  MAX_SENTENCES = 20

  belongs_to :site
  belongs_to :scene, optional: true
  belongs_to :point, optional: true

  before_validation { self.sentences = Array(sentences).flat_map { |s| s.to_s.split("\n") }.map(&:squish).compact_blank.uniq.first(MAX_SENTENCES) }
  normalizes :name, :response, with: ->(v) { v.to_s.squish.presence }
  normalizes :language, with: ->(v) { v.to_s.presence_in(Assist::LANGUAGES) }

  validates :name, presence: true, length: { maximum: 60 }
  validates :response, length: { maximum: 300 }
  validate :sentences_fit
  validate :target_fits

  audited_attributes :name, :language, :sentences, :scene_id, :point_id, :response, :enabled

  scope :enabled, -> { where(enabled: true) }

  # Formulário: uma frase por linha.
  def sentences_text = sentences.join("\n")
  def sentences_text=(text)
    self.sentences = text.to_s.split("\n")
  end

  # Alvo do formulário/API em um campo: "scene:<id>" ou "script:<id do ponto>".
  def target = scene_id ? "scene:#{scene_id}" : ("script:#{point_id}" if point_id)
  def target=(ref)
    kind, id = ref.to_s.split(":", 2)
    self.scene_id = kind == "scene" ? id.presence : nil
    self.point_id = kind == "script" ? id.presence : nil
  end

  def target_name = scene&.name || point&.name
  def risk = scene&.risk || point&.risk

  # Escolhas do alvo: cenas e scripts do local que a voz pode acionar (sem crítico).
  def self.targets(site)
    scenes = site.scenes.order(:name).reject { |s| s.risk == "critical" }.map { |s| [ s.name, "scene:#{s.id}" ] }
    scripts = site.points.where(capability: "script").where.not(risk: "critical").order(:name).map { |p| [ p.name, "script:#{p.id}" ] }
    [ [ I18n.t("custom.voice.scenes"), scenes ], [ I18n.t("custom.voice.scripts"), scripts ] ]
  end

  # Slots da frase normalizada no idioma (nil = não casa).
  def match(norm, language)
    return nil if self.language && self.language != language

    sentences.each do |s|
      found = Assist::Sentences.match(s, norm) and return found
    end
    nil
  end

  # Resposta com `{slot}` trocado; nil (= a padrão) se a frase dita não trouxe um slot que ela usa.
  def answer(slots)
    return nil if Assist::Sentences.slots(response).any? { |s| slots[s].blank? }

    response.to_s.gsub(/\{(\w+)\}/) { slots[::Regexp.last_match(1)].to_s }.squish
  end

  private

  def sentences_fit
    return errors.add(:sentences, :blank) if sentences.empty?

    sentences.each do |s|
      err = Assist::Sentences.error(s) and errors.add(:sentences, :invalid_sentence, sentence: s.truncate(40), error: err)
    end
  end

  def target_fits
    return errors.add(:base, :target_missing) if scene_id.nil? == point_id.nil?
    return errors.add(:scene, :other_site) if scene && scene.site_id != site_id
    return errors.add(:point, :not_script) if point && (point.site_id != site_id || point.capability != "script")

    errors.add(:base, :critical_target) if risk == "critical"
  end
end
