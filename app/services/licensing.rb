# Planos do produto (base): free/plus/pro por instalação, com limites. Não é a
# assinatura da IA (Plans/Billing, cobrada pela Play): é a licença de uso do
# produto vendido. Os tipos de limite são um registro (`LIMITS`, cada um diz
# como medir o uso); os valores de cada plano ficam em `PLANS` e a instalação
# pode ter os próprios em `tenants.settings["license"]["limits"]`.
#
# Instalação sem licença gravada = `DEFAULT` (LICENSE_DEFAULT_PLAN, padrão
# "pro" ilimitado: quem já usa não perde nada). Pagamento ainda não existe:
# `PAYMENT_PROVIDERS` é o registro vazio (contrato em docs/planos.md).
module Licensing
  # nil = sem limite; true/false = recurso liga/desliga.
  PLANS = {
    "free" => { "devices" => 25, "users" => 3, "history_days" => 30, "cloud_backup" => false, "remote_access" => false },
    "plus" => { "devices" => 150, "users" => 10, "history_days" => 365, "cloud_backup" => true, "remote_access" => true },
    "pro" => { "devices" => nil, "users" => nil, "history_days" => nil, "cloud_backup" => true, "remote_access" => true }
  }.freeze
  LIMITS = %w[Devices Users HistoryDays CloudBackup RemoteAccess].freeze
  PAYMENT_PROVIDERS = [].freeze

  Exceeded = Class.new(StandardError)

  module_function

  def default_plan = ENV.fetch("LICENSE_DEFAULT_PLAN", "pro").presence_in(PLANS.keys) || "pro"
  def limits = LIMITS.map { |n| const_get(n) }
  def limit_type(key) = limits.find { |l| l.key == key.to_s }
  def license(tenant) = tenant.settings["license"] || {}
  def plan(tenant) = license(tenant)["plan"].presence_in(PLANS.keys) || default_plan

  # Valor do limite na instalação (o próprio dela vence o do plano).
  def limit(tenant, key)
    own = license(tenant)["limits"].to_h
    own.key?(key.to_s) ? own[key.to_s] : PLANS.fetch(plan(tenant))[key.to_s]
  end

  # Cabe mais `adding`? (recurso: está ligado?)
  def allowed?(tenant, key, adding: 1)
    value = limit(tenant, key)
    return value == true if [ true, false ].include?(value)
    return true if value.nil?

    limit_type(key).usage(tenant) + adding <= value
  end

  def check!(tenant, key, adding: 1) = allowed?(tenant, key, adding: adding) || raise(Exceeded, message(key))
  def message(key) = I18n.t("plan.exceeded", what: I18n.t("plan.limits.#{key}"))

  def set!(tenant, plan, limits: nil)
    raise ArgumentError, "plano desconhecido" unless PLANS.key?(plan.to_s)

    tenant.update!(settings: tenant.settings.merge("license" => { "plan" => plan.to_s, "limits" => limits }.compact))
  end

  # Tipo de limite: chave, `kind` (:count, :days, :flag) e o uso de agora.
  class Limit
    class << self
      attr_reader :key, :kind

      def describe(key:, kind:)
        @key = key
        @kind = kind
      end

      def usage(_tenant) = 0
    end
  end

  class Devices < Limit
    describe key: "devices", kind: :count
    def self.usage(tenant) = ActsAsTenant.with_tenant(tenant) { Device.listed.count }
  end

  class Users < Limit
    describe key: "users", kind: :count
    def self.usage(tenant) = tenant.users.where(disabled_at: nil).count
  end

  class HistoryDays < Limit
    describe key: "history_days", kind: :days
  end

  class CloudBackup < Limit
    describe key: "cloud_backup", kind: :flag
  end

  class RemoteAccess < Limit
    describe key: "remote_access", kind: :flag
  end
end
