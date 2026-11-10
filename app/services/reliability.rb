# Confiabilidade (docs/confiabilidade.md): aparelho sem sinal, execuções sem
# dono e falhas repetidas. Ajustes por instalação em
# `tenants.settings["reliability"]` (padrões em DEFAULTS):
#   dead_device_hours  aparelho sem sinal há mais disso: automação não comanda (24)
#   run_max_minutes    execução "rodando" sem atualizar há mais disso foi interrompida (15)
#   failure_streak     falhas seguidas que viram aviso (ponto, automação) (3)
module Reliability
  DEFAULTS = { "dead_device_hours" => 24, "run_max_minutes" => 15, "failure_streak" => 3 }.freeze
  # Status de aparelho que dizem "sem sinal" (mantidos pela leitura periódica e pelos ouvintes).
  NO_SIGNAL = %w[offline error].freeze

  module_function

  def setting(key, tenant = ActsAsTenant.current_tenant)
    value = tenant&.settings.to_h.dig("reliability", key.to_s)
    value.to_i.positive? ? value.to_i : DEFAULTS.fetch(key.to_s)
  end

  def dead_after(tenant = ActsAsTenant.current_tenant) = setting(:dead_device_hours, tenant).hours
  def run_max(tenant = ActsAsTenant.current_tenant) = setting(:run_max_minutes, tenant).minutes
  def streak(tenant = ActsAsTenant.current_tenant) = setting(:failure_streak, tenant)

  # Há quanto tempo (segundos) o aparelho está sem sinal, se passou do limite;
  # nil = tem sinal (ou não dá para saber). Sem sinal = status offline/erro
  # (leitura periódica, ouvinte) OU os últimos comandos falharam; em ambos, o
  # último contato (visto ou comando confirmado) ficou para trás do limite.
  # Comando pulado não conta: quem tira o aparelho daqui é a leitura ou um
  # comando de pessoa que dá certo.
  def signal_lost(device, now: Time.current, tenant: device.tenant)
    return nil if device.virtual? || device.disabled

    limit = dead_after(tenant)
    since = last_contact(device)
    return nil if since ? since > now - limit : device.created_at > now - limit
    return nil unless NO_SIGNAL.include?(device.status) || failing?(device)

    now - (since || device.created_at)
  end

  def last_contact(device)
    confirmed = Command.where(point_id: device.points.select(:id), status: "confirmed").maximum(:confirmed_at)
    [ device.last_seen_at, confirmed ].compact.max
  end

  # Os últimos comandos que chegaram ao fim (confirmado/falhou) falharam todos.
  def failing?(device, n = streak(device.tenant))
    last = Command.where(point_id: device.points.select(:id), status: %w[confirmed failed]).order(created_at: :desc).limit(n).pluck(:status)
    last.size == n && last.all?("failed")
  end

  # "3 dias", "26 h", "45 min" (texto do trace e do erro do comando).
  def duration_text(seconds)
    s = seconds.to_i
    return "#{s / 86_400} dias" if s >= 2.days
    return "#{s / 3600} h" if s >= 1.hour

    "#{[ s / 60, 1 ].max} min"
  end

  # Aparelhos sem sinal do local além do limite (Saúde).
  def dead_devices(site, now: Time.current)
    candidates = site.devices.listed.where(disabled: false, removed_at: nil).where.not(driver: "virtual")
    candidates.order(:name).filter_map { |d| (lost = signal_lost(d, now: now)) && [ d, lost ] }
  end
end
