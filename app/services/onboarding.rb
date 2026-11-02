# Primeira configuração (produto): o assistente da instalação nova. Cada
# passo é um plugin (`Onboarding::Step`, um arquivo em
# app/services/onboarding/steps/) registrado em `STEPS`, com a partial
# `web/onboarding/steps/_<key>`; o controller só segue a lista. Passo novo =
# classe + nome aqui + partial + textos em config/locales/web.*.yml.
#
# Aparece quando não há ninguém (instalação nova: o primeiro passo cria o
# dono) ou para o dono de uma instalação sem local, até ele concluir. O
# estado fica em `tenants.settings["onboarding"]` ({done: [chaves], site_id,
# finished_at}).
module Onboarding
  STEPS = %w[AccountStep HomeStep DiscoverStep AreasStep DashboardStep FamilyStep].freeze

  # O que os passos compartilham: quem está configurando, o local criado e a
  # resposta da tela (aviso, convite gerado) quando o passo fica na mesma página.
  Context = Struct.new(:user, :site, :base_url, :notice, :data, keyword_init: true) do
    def tenant = user&.tenant
  end

  module_function

  def steps = STEPS.map { |name| Steps.const_get(name) }
  def step(key) = steps.find { |s| s.key == key.to_s }

  # Ninguém cadastrado: a instalação acabou de subir.
  def fresh_install? = !User.exists?

  def state(tenant) = tenant&.settings&.dig("onboarding") || {}

  # O dono ainda não concluiu e a instalação está sem local (ou já começou o assistente).
  def pending?(user)
    return false unless user&.owner?

    s = state(user.tenant)
    s["finished_at"].blank? && (s["site_id"].present? || ActsAsTenant.with_tenant(user.tenant) { !Site.exists? })
  end

  def context(user, base_url: nil)
    site = user && ActsAsTenant.with_tenant(user.tenant) { Site.find_by(id: state(user.tenant)["site_id"]) || Site.order(:created_at).first }
    Context.new(user: user, site: site, base_url: base_url, data: {})
  end

  # Passos desta pessoa (o de conta some para quem já entrou com conta pronta).
  def steps_for(ctx) = steps.reject { |s| s.skip?(ctx) }

  def done?(ctx, key) = Array(state(ctx.tenant)["done"]).include?(key.to_s)

  # O primeiro que dá para abrir e ainda não foi feito (ou o último que dá).
  def current(ctx)
    list = steps_for(ctx).select { |s| s.ready?(ctx) }
    list.find { |s| !done?(ctx, s.key) } || list.last
  end

  def update!(tenant, **changes)
    tenant.update!(settings: tenant.settings.merge("onboarding" => state(tenant).merge(changes.stringify_keys)))
  end

  def mark_done!(ctx, step)
    update!(ctx.tenant, done: (Array(state(ctx.tenant)["done"]) | [ step.key ]), site_id: ctx.site&.id)
  end

  def finish!(tenant) = update!(tenant, finished_at: Time.current.iso8601)
end
