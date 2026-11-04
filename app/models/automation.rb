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
#
# Script (F8f, `kind: "script"`): só ações, com campos (`fields`: nome,
# rótulo, tipo, padrão, obrigatório, opções); quem chama é a ação "Executar
# script", o botão do painel (ponto de capacidade `script`, Scripts), a API e
# o "Executar". Mesmas versões, modos e execuções (trace) das automações.
# Criada por blueprint: `blueprint` + `blueprint_inputs` (+ a versão usada).
class Automation < ApplicationRecord
  include Labelable
  include Auditable

  acts_as_tenant :tenant

  MODES = LocalizedLabel.for("automations.dsl.modes", Automations::Dsl::MODES)
  KINDS = LocalizedLabel.for("automations.labels.kinds", %w[automation script])
  FIELD_TYPES = LocalizedLabel.for("automations.labels.field_types", %w[text number boolean point select])
  MAX_PER_MINUTE = 30
  # Corrente de automações (uma disparando a outra). Abaixo do limite das
  # primitivas (Automations::MAX_DEPTH), para o laço evitado ficar no trace.
  MAX_DEPTH = 3
  # Mudança de ponto até esse tempo depois de um comando de automação nele
  # conta como causada por ela (aparelho real confirma em 1 a 3 s).
  CAUSE_WINDOW = 10.seconds

  belongs_to :site
  belongs_to :area, optional: true
  belongs_to :blueprint, optional: true
  has_many :versions, -> { order(version: :desc) }, class_name: "AutomationVersion", dependent: nil # cascade no banco
  has_many :runs, class_name: "AutomationRun", dependent: nil

  encrypts :webhook_token, deterministic: true

  before_validation :normalize_definitions

  validates :name, presence: true
  validates :mode, inclusion: { in: MODES.keys }
  validates :kind, inclusion: { in: KINDS.keys }
  validate :fields_valid
  validates :max_runs, numericality: { only_integer: true, in: 1..50 }
  validate :definitions_valid
  validate { errors.add(:enabled, :unpublished) if enabled && !published? }
  validate { errors.add(:area, :other_site) if area && area.site_id != site_id }

  normalizes :name, with: ->(v) { v.to_s.squish }
  normalizes :category, with: ->(v) { v.to_s.squish.presence }

  audited_attributes :name, :enabled, :mode, :version, :shadow

  scope :ordered, -> { order(:name) }

  after_save { script? ? Scripts.sync!(self) : AutomationPoints.sync!(self) }
  after_destroy { script? ? Scripts.remove!(self) : AutomationPoints.remove!(self) }

  def script? = kind == "script"
  def kind_label = KINDS.fetch(kind, kind)
  def mode_label = MODES.fetch(mode, mode)
  def errors_in(defn) = Automations::Dsl.errors(defn, site, fields: (fields if script?))
  def blueprint_outdated? = blueprint.present? && blueprint_version.to_i < blueprint.version

  def published? = version.positive?
  def draft? = draft.present?
  def working_draft = draft || (published? ? definition : (script? ? { "actions" => [] } : Automations::Dsl.empty))
  def webhook? = Array(definition["triggers"]).any? { |t| t["type"] == "webhook" }

  def definition_for(number)
    number == version ? definition : versions.find_by!(version: number).definition
  end

  # Publica o rascunho (ou `new_definition`, da API) como versão nova.
  def publish!(new_definition = draft, author: Current.user)
    raise ArgumentError, I18n.t("automations.errors.nothing_to_publish") if new_definition.blank?

    transaction do
      update!(definition: new_definition, draft: nil, version: version + 1, blueprint_version: blueprint&.version)
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

  # Script: valores dos campos (padrão, tipo e obrigatório). Levanta
  # ArgumentError com a mensagem para a tela.
  def field_values(given)
    given = given.to_h.stringify_keys
    unknown = given.keys - fields.pluck("name")
    raise ArgumentError, I18n.t("automations.errors.unknown_field", fields: unknown.join(", ")) if unknown.any?

    values = cast_fields(given.compact_blank)
    fields.each do |fd|
      values[fd["name"]] = fd["default"] if !values.key?(fd["name"]) && !fd["default"].nil?
      raise ArgumentError, I18n.t("automations.errors.missing_field", field: fd["label"]) if fd["required"] && values[fd["name"]].nil?
    end
    values
  end

  # Texto do formulário → tipo do campo (o que não converte levanta ArgumentError).
  def cast_fields(given)
    by_name = fields.index_by { |fd| fd["name"] }
    given.to_h.stringify_keys.to_h do |name, raw|
      fd = by_name[name] or next [ name, raw ]
      [ name, cast_field(fd, raw) ]
    end
  end

  def field_defaults = fields.to_h { |fd| [ fd["name"], fd["default"] ] }.compact

  # Pontos escolhidos nos campos de tipo ponto (papel x risco de quem chama).
  def point_field_values(given)
    names = fields.select { |fd| fd["type"] == "point" }.pluck("name")
    refs = given.to_h.stringify_keys.values_at(*names).compact.map(&:to_s)
    refs.empty? ? [] : site.points.where(id: refs.grep(UUID)).or(site.points.where(key: refs)).pluck(:id)
  end

  # Risco de executar com esses campos: o do script e o dos pontos escolhidos.
  def run_risk(values = {})
    risks = [ max_risk(definition), *site.points.where(id: point_field_values(values)).pluck(:risk) ]
    risks.max_by { |r| Point::RISKS.keys.index(r) }
  end

  def run_script!(values, title:, cause: nil, user: nil)
    fire!({ "type" => "script", "title" => title, "fields" => values, "user_id" => user&.id }.compact, cause: cause, skip_conditions: true)
  end

  # Simulação: roda o rascunho (ou a publicada) a seco, com valores
  # hipotéticos de pontos e hora. Grava a execução (`dry_run`) para o trace.
  def simulate!(points: {}, at: nil, trigger: {}, definition: working_draft, skip_conditions: false)
    at = at.presence && (at.is_a?(String) ? Time.zone.parse(at) : at)
    trigger = { "type" => "manual", "title" => "Simulação" }.merge(trigger.to_h.stringify_keys)
    run = runs.create!(tenant_id: tenant_id, site: site, version: (version if definition == self.definition), trigger: trigger, status: "running",
                       dry_run: true, started_at: Time.current)
    ctx = Automations::Context.new(site: site, trigger: trigger, vars: (field_defaults if script?), overrides: points, at: at)
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

  # Sombra (F10): a própria marca, o local, a instalação, quem causou ou a
  # thread já em sombra (script chamado pelo ponto dentro de uma execução).
  def new_run(trigger, cause, depth, status)
    shadow = Shadow.active?(self) || cause&.shadow || Shadow.current.present?
    runs.create!(tenant_id: tenant_id, site: site, version: version, trigger: trigger, status: status, cause_run: cause, depth: depth, shadow: shadow,
                 started_at: Time.current, steps: [ { "at" => Time.current.iso8601(3), "kind" => "trigger", "title" => trigger["title"] || "Disparo", "result" => "ok" } ])
  end

  def start(run)
    ctx = Automations::Context.new(site: site, trigger: run.trigger, vars: run.trigger["fields"].to_h)
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
    errors.add(:draft, :not_object) unless draft.nil? || draft.is_a?(Hash)
    return unless published? && site

    errors_in(definition).first(5).each { |e| errors.add(:definition, e) }
  end

  UUID = /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/

  def cast_field(fd, raw)
    case fd["type"]
    when "number" then raw.is_a?(Numeric) ? raw : number_field(fd, raw)
    when "boolean" then ActiveModel::Type::Boolean.new.cast(raw)
    when "point" then point_ref(raw.to_s)&.id || raise(ArgumentError, I18n.t("automations.errors.field_point", field: fd["label"]))
    when "select" then raw.to_s.presence_in(Array(fd["options"]).map(&:to_s)) || raise(ArgumentError, I18n.t("automations.errors.field_option", field: fd["label"]))
    else raw.to_s.truncate(500)
    end
  end

  def number_field(fd, raw)
    n = Float(raw.to_s.tr(",", "."), exception: false) or raise ArgumentError, I18n.t("automations.errors.field_number", field: fd["label"])
    n % 1 == 0 ? n.to_i : n
  end

  def point_ref(ref) = (site.points.find_by(id: ref) if UUID.match?(ref)) || site.points.find_by(key: ref)

  # Campos do script: nome de variável único, tipo conhecido, seleção com opções.
  def fields_valid
    return errors.add(:fields, :not_list) unless fields.is_a?(Array)
    return if fields.empty?
    return errors.add(:fields, :script_only) unless script?

    names = fields.map { |fd| fd.is_a?(Hash) && fd["name"] }
    errors.add(:fields, :bad_name) unless names.all? { |n| n.is_a?(String) && Automations::Dsl::VAR.match?(n) }
    errors.add(:fields, :repeated) if names.uniq.size != names.size
    fields.each do |fd|
      next unless fd.is_a?(Hash)

      errors.add(:fields, :bad_type, name: fd["name"]) unless FIELD_TYPES.key?(fd["type"])
      errors.add(:fields, :no_options, name: fd["name"]) if fd["type"] == "select" && Array(fd["options"]).empty?
    end
  end
end
