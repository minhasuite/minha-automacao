module Notifications
  # Resumo diário opcional (docs/push.md, "Resumo diário"): na hora que a
  # pessoa escolheu (`prefs["digest"]`, fuso do primeiro local), um push só
  # com o que aconteceu nas últimas 24 h e a tela `/notificacoes/resumo`.
  # Cada parte é um plugin em `SECTIONS` (`describe key:, label:, icon:` +
  # `lines(user, sites, range)` → textos); parte nova = classe + nome aqui,
  # nada muda na tela, no push nem no app.
  module Digest
    SECTIONS = %w[Openings Alerts Failures Battery Notices].freeze
    PERIOD = 24.hours

    # Base dos plugins de parte.
    class Section
      class << self
        attr_reader :key, :icon

        def describe(key:, icon:) = (@key, @icon = key, icon)
        def label = I18n.t("notifications.digest.sections.#{key}")
      end
    end

    module_function

    def sections = SECTIONS.map { |name| const_get(name) }

    # Locais que a pessoa vê.
    def sites_for(user) = Site.order(:name).select { |s| s.role_for(user) }

    # [{key, label, icon, lines}] das partes com algo a dizer.
    def build(user, now = Time.current)
      range = (now - PERIOD)..now
      sites = sites_for(user)
      sections.filter_map do |s|
        lines = Array(s.lines(user, sites, range)).compact_blank
        { "key" => s.key, "label" => s.label, "icon" => s.icon, "lines" => lines } if lines.any?
      end
    end

    # RunSchedulesJob, a cada minuto: quem tem o resumo ligado e já passou da hora hoje.
    def tick(now = Time.current)
      users = ActsAsTenant.without_tenant do
        User.where(disabled_at: nil).where("users.dashboard_prefs->'notifications'->'digest'->>'enabled' = 'true'").to_a
      end
      users.each do |user|
        ActsAsTenant.with_tenant(user.tenant) { deliver(user, now) if due?(user, now) }
      rescue StandardError => e
        Rails.error.report(e, handled: true)
      end
    end

    def due?(user, now)
      at = Notifications.user_prefs(user).dig("digest", "at").to_s
      return false unless Notifications::TIME.match?(at)

      local = now.in_time_zone(Notifications.zone(user.tenant))
      local.strftime("%H:%M") >= at && !Notification.exists?(dedup_key: dedup_key(user, local.to_date))
    end

    def dedup_key(user, date) = "digest:#{user.id}:#{date.iso8601}"

    def deliver(user, now = Time.current)
      I18n.with_locale(user.dashboard_prefs.to_h["locale"].presence_in(I18n.available_locales.map(&:to_s)) || I18n.default_locale) do
        parts = build(user, now)
        body = parts.any? ? parts.flat_map { |p| p["lines"] }.first(6).join(" · ") : I18n.t("notifications.digest.quiet_day")
        date = now.in_time_zone(Notifications.zone(user.tenant)).to_date
        Notifier.notify!(kind: "resumo_diario", user: user, title: I18n.t("notifications.digest.title"), body: body.truncate(1000),
                         data: { "url" => "/notificacoes/resumo", "tag" => "resumo-diario" }, dedup_key: dedup_key(user, date))
      end
    rescue Shadow::Blocked
      nil
    end
  end
end
