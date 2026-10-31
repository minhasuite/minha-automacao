# Avisos: cria a notificação (o registro que todo canal leva) e entrega pelos
# canais escolhidos. Cada canal é um plugin em Notifier::Channels (CHANNELS):
# no app, push (que por sua vez tem transportes: Web Push e FCM) e fala na
# Echo. Canal novo = classe com `owns?(canal)`, `choices(site)`, `label(canal)`,
# `capabilities` e `deliver(canal, notificações)` [+ `speak(canal, texto,
# chime:)` se for canal de fala] + nome em CHANNELS; nada
# muda aqui, na ação "Avisar" nem no editor. O aviso declara o que quer
# (título, corpo, botões, imagem, link, tag, prioridade, validade...) e cada
# canal usa o que suporta (`capabilities`) e ignora o resto.
#
# Com `user`, só para a pessoa; sem, para os administradores da empresa.
# `dedup_key` repetido = não cria de novo (devolve nil).
module Notifier
  CHANNELS = %w[InApp Push Alexa].freeze
  # Destinatário da ação "Avisar" (Lote 1): administradores (padrão), uma
  # pessoa (todos os aparelhos dela) ou quem tem pelo menos um papel no local
  # (`role:guest` = todos do local): `admins`, `user:<id>` ou `role:<papel>`.
  UUID = /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/
  # Tudo o que um aviso pode pedir; o canal diz o que entrega.
  FEATURES = %i[text buttons image link tag priority ttl sticky group].freeze

  module_function

  def channels = CHANNELS.map { |name| Channels.const_get(name) }
  def channel_for(channel) = channels.find { |c| c.owns?(channel.to_s) }
  # Canais "fixos" (sem alvo próprio): o padrão do bloco novo.
  def default_channels = channels.flat_map { |c| c.respond_to?(:default) ? Array(c.default) : [] }

  def valid_channels?(list) = list.is_a?(Array) && list.any? && list.all? { |c| channel_for(c) }

  def channel_choices(site) = channels.flat_map { |c| c.choices(site) }

  # Canais de fala (Lote 3): os que respondem a `speak(canal, texto, chime:)`; a ação "Falar" usa só estes.
  def speech_channel?(channel) = channel_for(channel).respond_to?(:speak)
  def speech_choices(site) = channels.select { |c| c.respond_to?(:speak) }.flat_map { |c| c.choices(site) }

  def channel_label(channel) = channel_for(channel)&.label(channel.to_s) || "Canal removido"

  def valid_recipient?(to)
    kind, ref = to.to_s.split(":", 2)
    return ref.nil? if kind == "admins"

    (kind == "user" && UUID.match?(ref.to_s)) || (kind == "role" && SiteMembership::ROLES.include?(ref))
  end

  def recipient_choices(site)
    [ [ "Administradores", "admins" ] ] +
      SiteMembership::ROLES.reverse.map { |r| [ r == "guest" ? "Todos do local" : "Quem é #{SiteMembership.role_label(r).downcase} ou mais no local", "role:#{r}" ] } +
      User.where(tenant_id: site.tenant_id, disabled_at: nil).order(:name).select { |u| site.role_for(u) }.map { |u| [ "#{u.name} (todos os aparelhos)", "user:#{u.id}" ] }
  end

  def recipient_label(to, site)
    recipient_choices(site).find { |_, v| v == to }&.first || "pessoa removida"
  end

  # Pessoas do destinatário (`[nil]` = administradores, notificação sem dono).
  def recipients(to, site)
    kind, ref = to.to_s.split(":", 2)
    return [ nil ] if kind.blank? || kind == "admins"

    people = User.where(tenant_id: site.tenant_id, disabled_at: nil)
    return people.where(id: ref).to_a if kind == "user"

    people.select { |u| (role = site.role_for(u)) && SiteMembership::ROLES.index(role) >= SiteMembership::ROLES.index(ref) }
  end

  # `to` + `site`: destinatário (uma notificação por pessoa). `clear`: só
  # apaga o aviso com a `data["tag"]`. Devolve a primeira notificação criada.
  def deliver!(channels, to: nil, site: nil, clear: false, image: nil, **opts)
    Shadow.block!("Avisar: #{opts[:title]}")
    users = to && site ? recipients(to, site) : [ opts.delete(:user) ]
    return clear!(users, opts.dig(:data, :tag) || opts.dig(:data, "tag")) if clear

    created = users.filter_map do |user|
      key = opts[:dedup_key] && users.size > 1 ? "#{opts[:dedup_key]}:#{user&.id}" : opts[:dedup_key]
      notify!(**opts, user: user, dedup_key: key, push: false, image: image)
    end
    if created.any?
      channels.each do |ch|
        channel_for(ch)&.deliver(ch.to_s, created)
      rescue StandardError => e
        Rails.error.report(e, handled: true) # um canal com erro não impede os outros
      end
    end
    created.first
  end

  # `image`: blob do Active Storage (quadro de câmera), anexado a cada notificação.
  # `push: true` também entrega pelo canal push (uso direto, fora da ação "Avisar").
  def notify!(kind:, title:, user: nil, body: nil, data: {}, dedup_key: nil, push: true, image: nil)
    Shadow.block!("Avisar: #{title}") if push
    return nil if dedup_key && Notification.exists?(dedup_key: dedup_key)

    data = data.to_h.stringify_keys
    notification = Notification.create!(kind: kind, user: user, title: title.to_s.truncate(200), body: body, data: data, dedup_key: dedup_key)
    notification.image.attach(image) if image
    # Tag igual substitui: o aviso anterior com a mesma tag sai da lista de não lidas.
    Notification.where(user_id: user&.id).tagged(data["tag"]).unread.where.not(id: notification.id).update_all(read_at: Time.current) if data["tag"].present? # rubocop:disable Rails/SkipsModelValidations
    Channels::Push.deliver("push", [ notification ]) if push
    notification
  rescue ActiveRecord::RecordNotUnique
    nil
  end

  # "Limpar aviso": marca como lido e pede a cada canal que apague o último aviso com a tag.
  def clear!(users, tag)
    return if tag.blank?

    users.each do |user|
      last = Notification.where(user_id: user&.id).tagged(tag).order(created_at: :desc).first or next
      Notification.where(user_id: user&.id).tagged(tag).unread.update_all(read_at: Time.current) # rubocop:disable Rails/SkipsModelValidations
      channels.each { |c| c.clear(last, tag) if c.respond_to?(:clear) }
    end
    nil
  end
end
