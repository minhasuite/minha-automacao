# Pipeline do Assist (ondaB1, B5; os "assistentes de voz" do HA): idioma,
# agente (local, local + IA com ferramentas, só IA), STT e TTS por motor
# (Assist::Engines: o da instalação, Wyoming...) e a palavra de ativação dos
# satélites. Um por local é o preferido (o que o botão Falar usa).
class AssistPipeline < ApplicationRecord
  acts_as_tenant :tenant

  belongs_to :site
  has_many :runs, class_name: "AssistRun", foreign_key: :pipeline_id, inverse_of: :pipeline, dependent: nil

  AGENTS = LocalizedLabel.for("assist_settings.agents", %w[local local_llm llm])

  validates :name, presence: true, length: { maximum: 60 }, uniqueness: { scope: :site_id }
  validates :language, inclusion: { in: Assist::LANGUAGES }
  validates :agent, inclusion: { in: AGENTS.keys }
  validate :engines_known

  normalizes :name, with: ->(v) { v.to_s.squish }
  normalizes :llm_provider, with: ->(v) { v.to_s.strip.presence }

  after_save :only_one_preferred, if: -> { preferred? && saved_change_to_preferred? }

  # Preferido do local, ou nil (comportamento de antes: motor da instalação, agente local).
  def self.for(site, id = nil)
    scope = where(site: site)
    (id.present? && scope.find_by(id: id)) || scope.find_by(preferred: true) || scope.order(:created_at).first
  end

  def engine(kind)
    cfg = send(kind)
    Assist::Engines[cfg["engine"]] if cfg.is_a?(Hash) && cfg["engine"].present?
  end

  private

  def engines_known
    %i[stt tts wake].each do |kind|
      cfg = send(kind)
      next if cfg.blank? || cfg["engine"].blank?

      plugin = Assist::Engines[cfg["engine"]]
      next errors.add(kind, :inclusion) unless plugin&.kinds&.include?(kind)

      plugin.check(cfg, kind).each { |msg| errors.add(kind, msg) }
    end
  end

  def only_one_preferred = AssistPipeline.where(site_id: site_id).where.not(id: id).update_all(preferred: false)
end
