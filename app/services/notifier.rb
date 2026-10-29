# Cria a notificação in-app e manda o push (FCM). Com `user`, só para a
# pessoa; sem, para os administradores da empresa. `dedup_key` repetido = não cria
# de novo (devolve nil). `push: false` grava só a notificação.
module Notifier
  # Canais das regras de aviso e de alerta (F4) e da ação "Avisar" da DSL. A
  # notificação in-app sempre nasce (é ela que o push leva); "push" liga o
  # FCM. F8: "alexa:<id do ponto speaker>" fala o aviso naquela Echo (comando
  # `announce` pela fila, como qualquer outro comando de automação).
  CHANNELS = { "in_app" => "No app", "push" => "Push no celular" }.freeze
  ALEXA = /\Aalexa:(\h{8}-\h{4}-\h{4}-\h{4}-\h{12})\z/

  module_function

  def valid_channels?(channels)
    channels.is_a?(Array) && channels.any? && channels.all? { |c| CHANNELS.key?(c) || c.to_s.match?(ALEXA) }
  end

  # Canais para escolher na tela: os fixos e uma Echo por ponto `speaker` do local.
  def channel_choices(site)
    CHANNELS.to_a + site.points.includes(:device).where(capability: "speaker", disabled: false).order(:name)
                        .map { |p| [ "alexa:#{p.id}", "Falar na #{p.device.name}" ] }.sort_by(&:last)
  end

  def channel_label(channel)
    return CHANNELS[channel] if CHANNELS.key?(channel)

    id = channel.to_s[ALEXA, 1]
    point = id && Point.includes(:device).find_by(id: id)
    point ? "Falar na #{point.device.name}" : "Echo removida"
  end

  def deliver!(channels, **)
    notification = notify!(**, push: channels.include?("push"))
    speak!(channels, [ notification.title, notification.body ].compact_blank.join(". ")) if notification
    notification
  end

  # Anuncia nas Echo dos canais; erro numa Echo não impede as outras nem o aviso.
  def speak!(channels, text)
    channels.filter_map { |c| c.to_s[ALEXA, 1] }.each do |id|
      point = Point.find_by(id: id, capability: "speaker") or next
      Points::Command.call(point, "announce", text.truncate(Points::Command::MAX_SPEECH), source: "automation", user: nil)
    rescue Points::Command::Error => e
      Rails.logger.warn("[notifier] alexa #{id}: #{e.message}")
    end
  end

  def notify!(kind:, title:, user: nil, body: nil, data: {}, dedup_key: nil, push: true)
    return nil if dedup_key && Notification.exists?(dedup_key: dedup_key)

    notification = Notification.create!(kind: kind, user: user, title: title.to_s.truncate(200), body: body, data: data, dedup_key: dedup_key)
    SendPushJob.perform_later(notification.id) if push && FeatureFlag.on?("push")
    notification
  rescue ActiveRecord::RecordNotUnique
    nil
  end
end
