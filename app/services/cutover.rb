# Pré-checagens da troca de sistema (docs/cutover.md): o que falta para tirar
# a instalação da sombra e desligar o sistema antigo. Requisito novo = uma
# entrada em `REQUIREMENTS` (rótulo + lambda que devolve [ok?, detalhe]).
# Aparece na tela de saúde (verificação "Pronto para a troca") e no
# `rake cutover:check`.
module Cutover
  SHADOW_DAYS = ENV.fetch("CUTOVER_SHADOW_DAYS", "7").to_i

  REQUIREMENTS = {
    "shadow_clean" => { label: "Sombra sem divergência por #{SHADOW_DAYS} dias", check: ->(_t) { Cutover.shadow_clean } },
    "integrations_ok" => { label: "Integrações conectadas", check: lambda { |_t|
      bad = Integration.where(status: %w[error pending]).order(:name).pluck(:name)
      [ bad.empty?, bad.empty? ? "Todas conectadas" : "Com problema: #{bad.join(', ')}" ]
    } },
    "offsite_backup" => { label: "Backup fora de casa e teste de restauração", check: lambda { |_t|
      ok = Backups.offsite_ok? && Backups.restore_ok?
      [ ok, ok ? "Cópia de hoje e restauração testada" : (Backups.configured? ? "Cópia ou teste de restauração atrasado/com falha" : "Não configurado") ]
    } },
    "app_installed" => { label: "App do celular instalado", check: lambda { |_t|
      n = Device.where(driver: Integrations.plugin("mobile_app")&.driver).count
      [ n.positive?, n.positive? ? "#{n} celular(es) com o app" : "Nenhum celular com o app" ]
    } },
    "push_ok" => { label: "Push chegando aos administradores", check: lambda { |t|
      admins = t.users.where(role: %w[owner admin], disabled_at: nil).pluck(:id)
      n = DeviceToken.where(user_id: admins, last_seen_at: 30.days.ago..).count + PushSubscription.where(user_id: admins).count
      [ n.positive?, n.positive? ? "#{n} aparelho(s) recebendo" : "Nenhum aparelho de administrador recebe push" ]
    } }
  }.freeze

  module_function

  def items(tenant)
    REQUIREMENTS.map do |key, r|
      ok, detail = r[:check].call(tenant)
      Health::Item.new(key: key, status: ok ? "ok" : "warn", title: r[:label], detail: detail)
    end
  end

  def ready?(tenant) = ActsAsTenant.with_tenant(tenant) { items(tenant).all? { |i| i.status == "ok" } }

  # Comparações cobrindo os últimos N dias, a mais nova de até 2 dias e nenhuma divergência na janela.
  def shadow_clean(now = Time.current)
    first = ShadowReport.minimum(:created_at)
    last = ShadowReport.maximum(:created_at)
    return [ false, "Nenhuma comparação da sombra ainda" ] unless first

    window = ShadowReport.where(created_at: (now - SHADOW_DAYS.days)..)
    divergent = window.count { |r| Health::Checks::Shadow.divergences(r).positive? }
    return [ false, "Comparações há #{((now - first) / 1.day).floor} dia(s); faltam dados de #{SHADOW_DAYS} dias" ] if first > now - SHADOW_DAYS.days
    return [ false, "Última comparação em #{I18n.l(last, format: :short)}: rode o comparador" ] if last < now - 2.days
    return [ false, "#{divergent} comparação(ões) com divergência nos últimos #{SHADOW_DAYS} dias" ] if divergent.positive?

    [ true, "#{window.count} comparação(ões) sem divergência" ]
  end
end
