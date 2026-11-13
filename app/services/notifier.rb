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
  CHANNELS = %w[InApp Push Alexa Messenger Player].freeze
  # Destinatário da ação "Avisar" (Lote 1): administradores (padrão), uma
  # pessoa (todos os aparelhos dela) ou quem tem pelo menos um papel no local
  # (`role:guest` = todos do local; `role:viewer` inclui os leitores): `admins`, `user:<id>` ou `role:<papel>`.
  ROLE_ALL = LocalizedLabel.for("automations.notifier.role_all", %w[guest viewer])
  UUID = /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/
  # Tudo o que um aviso pode pedir; o canal diz o que entrega.
  FEATURES = %i[text buttons image link tag priority ttl sticky group progress].freeze

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

  def channel_label(channel) = channel_for(channel)&.label(channel.to_s) || I18n.t("automations.notifier.channel_removed")

  def valid_recipient?(to)
    kind, ref = to.to_s.split(":", 2)
    return ref.nil? if kind == "admins"

    (kind == "user" && UUID.match?(ref.to_s)) || (kind == "role" && SiteMembership::ROLES.include?(ref))
  end

  def recipient_choices(site)
    [ [ I18n.t("automations.notifier.admins"), "admins" ] ] +
      SiteMembership::ROLES.reverse.map { |r| [ ROLE_ALL[r]&.to_s || I18n.t("automations.notifier.role_or_more", role: SiteMembership.role_label(r).downcase), "role:#{r}" ] } +
      User.where(tenant_id: site.tenant_id, disabled_at: nil).order(:name).select { |u| site.role_for(u) }.map { |u| [ I18n.t("automations.notifier.user_devices", name: u.name), "user:#{u.id}" ] }
  end

  def recipient_label(to, site)
    recipient_choices(site).find { |_, v| v == to }&.first || I18n.t("automations.notifier.person_removed")
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
    deliver_channels(channels, created) if created.any?
    created.first
  end

  # Canal que entrega vários alvos de uma vez (`deliver_all`, ex.: um anúncio
  # só para as Echo da mesma conta) recebe todos os seus; os outros, um a um.
  # Canal da casa (`quiet_scope` :house: fala, mensageiro) fica calado no
  # horário de silêncio da casa, a não ser em aviso crítico; o push (:person)
  # decide por pessoa (Push.deliver). Docs: docs/push.md, "Menos ruído".
  def deliver_channels(channels, created)
    house_quiet = Notifications.hold_house?(created.first)
    channels.map(&:to_s).group_by { |ch| channel_for(ch) }.each do |plugin, list|
      next unless plugin
      next if house_quiet && plugin.respond_to?(:quiet_scope) && plugin.quiet_scope == :house

      if plugin.respond_to?(:deliver_all)
        safely { plugin.deliver_all(list, created) }
      else
        list.each { |ch| safely { plugin.deliver(ch, created) } }
      end
    end
  end

  # Ação "Falar" nos canais de fala, agrupando como acima (`speak_all`).
  def speak!(channels, text, chime: true)
    channels.map(&:to_s).group_by { |ch| channel_for(ch) }.each do |plugin, list|
      next unless plugin

      plugin.respond_to?(:speak_all) ? plugin.speak_all(list, text, chime: chime) : list.each { |ch| plugin.speak(ch, text, chime: chime) }
    end
  end

  def safely
    yield
  rescue StandardError => e
    Rails.error.report(e, handled: true) # um canal com erro não impede os outros
  end

  # `image`: blob do Active Storage (quadro de câmera), anexado a cada notificação.
  # `push: true` também entrega pelo canal push (uso direto, fora da ação "Avisar").
  def notify!(kind:, title:, user: nil, body: nil, data: {}, dedup_key: nil, push: true, image: nil)
    Shadow.block!("Avisar: #{title}") if push
    return nil if dedup_key && Notification.exists?(dedup_key: dedup_key)

    data = data.to_h.stringify_keys
    # Fala em SSML (importada do HA): a tela e o push mostram o texto; a Echo usa o SSML.
    data["ssml"], body = body, Ssml.plain(body) if Ssml.ssml?(body)
    # Mesmo assunto dentro da janela: atualiza o aviso que já existe (Notifications::Merge).
    if !dedup_key && (merged = Notifications::Merge.into(user, Ssml.plain(title.to_s), body, data))
      merged.image.attach(image) if image
      Channels::Push.deliver("push", [ merged ]) if push
      return merged
    end
    data = Notifications::Merge.prepare(Ssml.plain(title.to_s), data)
    notification = Notification.create!(kind: kind, user: user, title: Ssml.plain(title.to_s).truncate(200), body: body, data: data, dedup_key: dedup_key)
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
