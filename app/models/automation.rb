# Automação (ESQUEMA-V1 §4.5 e §5): gatilhos, condições e ações na DSL JSON
# (Automations::Dsl). `definition` = versão publicada (é a que roda), `draft`
# = rascunho do editor; publicar e voltar versão gravam AutomationVersion.
# Nasce desligada; só liga depois de publicada.
#
# Modos (como no HA), quando dispara com outra execução em andamento:
#   single   → ignora o disparo novo
#   restart  → cancela a anterior e começa de novo
#   queued   → entra na fila (até `max_runs`) e roda quando a anterior acabar
#   parallel → roda junto (até `max_runs` ao mesmo tempo)
# Proteções: disparo causado pela própria automação (ou corrente com mais de
# MAX_DEPTH automações) vira execução "laço evitado" e não roda; mais de
# MAX_PER_MINUTE execuções por minuto são ignoradas.
class Automation < ApplicationRecord
  include Auditable

  acts_as_tenant :tenant

  MODES = Automations::Dsl::MODES
  MAX_PER_MINUTE = 30
  # Corrente de automações (uma disparando a outra). Abaixo do limite das
  # primitivas (Automations::MAX_DEPTH), para o laço evitado ficar no trace.
  MAX_DEPTH = 3
  # Mudança de ponto até esse tempo depois de um comando de automação nele
  # conta como causada por ela (aparelho real confirma em 1 a 3 s).
  CAUSE_WINDOW = 10.seconds

  belongs_to :site
  belongs_to :area, optional: true
  has_many :versions, -> { order(version: :desc) }, class_name: "AutomationVersion", dependent: nil # cascade no banco
  has_many :runs, class_name: "AutomationRun", dependent: nil

  encrypts :webhook_token, deterministic: true

  before_validation :normalize_definitions

  validates :name, presence: true
  validates :mode, inclusion: { in: MODES.keys }
  validates :max_runs, numericality: { only_integer: true, in: 1..50 }
  validate :definitions_valid
  validate { errors.add(:enabled, "só depois de publicar uma versão") if enabled && !published? }
  validate { errors.add(:area, "precisa ser deste local") if area && area.site_id != site_id }

  normalizes :name, with: ->(v) { v.to_s.squish }

  audited_attributes :name, :enabled, :mode, :version

  scope :ordered, -> { order(:name) }

  def mode_label = MODES.fetch(mode, mode)
  def published? = version.positive?
  def draft? = draft.present?
  def working_draft = draft || (published? ? definition : Automations::Dsl.empty)
  def webhook? = Array(definition["triggers"]).any? { |t| t["type"] == "webhook" }

  def definition_for(number)
    number == version ? definition : versions.find_by!(version: number).definition
  end

  # Publica o rascunho (ou `new_definition`, da API) como versão nova.
  def publish!(new_definition = draft, author: Current.user)
    raise ArgumentError, "nada para publicar" if new_definition.blank?

    transaction do
      update!(definition: new_definition, draft: nil, version: version + 1)
      versions.create!(tenant_id: tenant_id, version: version, definition: definition, author: author)
    end
  end

  def revert!(number, author: Current.user) = publish!(versions.find_by!(version: number).definition, author: author)

  def regenerate_webhook_token! = update!(webhook_token: SecureRandom.urlsafe_base64(24))

  # Risco mais alto entre os pontos comandados (rascunho ou publicada).
  def max_risk(defn = working_draft) = Automations::Dsl.max_risk(defn, site)

  # Dispara a versão publicada. Devolve a execução (ou nil se o modo/limite
  # descartou o disparo). `skip_conditions`: "executar agora" (como no HA).
  def fire!(trigger, cause: nil, skip_conditions: false)
    return unless published?

    trigger = trigger.stringify_keys.merge("skip_conditions" => (true if skip_conditions)).compact
    depth = cause ? cause.depth + 1 : 0
    return loop_run(trigger, cause, depth) if cause && (cause.automation_id == id || depth > MAX_DEPTH)

    run = with_lock { admit(trigger, cause, depth) }
    run&.status == "running" ? start(run) : run
  end

  # Simulação: roda o rascunho (ou a publicada) a seco, com valores
  # hipotéticos de pontos e hora. Grava a execução (`dry_run`) para o trace.
  def simulate!(points: {}, at: nil, trigger: {}, definition: working_draft, skip_conditions: false)
    at = at.presence && (at.is_a?(String) ? Time.zone.parse(at) : at)
    trigger = { "type" => "manual", "title" => "Simulação" }.merge(trigger.to_h.stringify_keys)
    run = runs.create!(tenant_id: tenant_id, site: site, version: (version if definition == self.definition), trigger: trigger, status: "running",
                       dry_run: true, started_at: Time.current)
    ctx = Automations::Context.new(site: site, trigger: trigger, overrides: points, at: at)
    run.steps << { "kind" => "trigger", "title" => "Gatilho simulado: #{trigger['title']}", "result" => "ok" }
    Automations::Engine.start(run, definition, ctx, skip_conditions: skip_conditions)
    run.reload
  end

  # Chamado pelo motor no fim de cada execução de verdade: última execução na
  # lista e a próxima da fila.
  def after_run(run)
    update_columns(last_run_at: run.started_at, last_status: run.status, last_error: (run.error if run.status == "failed")) # rubocop:disable Rails/SkipsModelValidations
    return if runs.active.exists?

    nxt = runs.real.where(status: "queued").order(:created_at).first or return
    start(nxt) if AutomationRun.where(id: nxt.id, status: "queued").update_all(status: "running", started_at: Time.current) == 1 # rubocop:disable Rails/SkipsModelValidations
  end

  private

  def admit(trigger, cause, depth)
    if runs.real.where(created_at: 1.minute.ago..).count >= MAX_PER_MINUTE
      update_columns(last_error: "Mais de #{MAX_PER_MINUTE} execuções num minuto: disparo ignorado.") # rubocop:disable Rails/SkipsModelValidations
      return
    end

    active = runs.active.to_a
    status = "running"
    case mode
    when "single" then return if active.any?
    when "restart" then active.each(&:cancel!)
    when "queued"
      return if active.any? && runs.real.where(status: "queued").count >= max_runs

      status = "queued" if active.any?
    when "parallel" then return if active.size >= max_runs
    end
    new_run(trigger, cause, depth, status)
  end

  def new_run(trigger, cause, depth, status)
    runs.create!(tenant_id: tenant_id, site: site, version: version, trigger: trigger, status: status, cause_run: cause, depth: depth,
                 started_at: Time.current, steps: [ { "at" => Time.current.iso8601(3), "kind" => "trigger", "title" => trigger["title"] || "Disparo", "result" => "ok" } ])
  end

  def start(run)
    ctx = Automations::Context.new(site: site, trigger: run.trigger)
    Automations::Engine.start(run, definition, ctx, skip_conditions: run.trigger["skip_conditions"] == true)
    run.reload
  end

  def loop_run(trigger, cause, depth)
    reason = cause.automation_id == id ? "disparada pela própria ação (#{cause.id.first(8)})" : "corrente com mais de #{MAX_DEPTH} automações"
    run = new_run(trigger, cause, depth, "loop")
    run.steps << { "kind" => "loop", "title" => "Laço evitado: #{reason}", "result" => "skipped" }
    run.update!(finished_at: Time.current, error: "Laço evitado: #{reason}")
    run
  end

  def normalize_definitions
    return unless site

    self.definition = Automations::Dsl.normalize(definition, site) if definition.present? && will_save_change_to_definition?
    self.draft = Automations::Dsl.normalize(draft, site) if draft.present? && will_save_change_to_draft?
  end

  # Só a publicada precisa estar completa: o rascunho do editor pode ter
  # bloco pela metade (os erros aparecem no editor e barram a publicação).
  def definitions_valid
    errors.add(:draft, "precisa ser um objeto JSON") unless draft.nil? || draft.is_a?(Hash)
    return unless published? && site

    Automations::Dsl.errors(definition, site).first(5).each { |e| errors.add(:definition, e) }
  end
end
