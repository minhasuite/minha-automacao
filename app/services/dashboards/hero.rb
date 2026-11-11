module Dashboards
  # Topo do painel configurável por visão (P1.4 da proposta de personalização):
  #
  #   "hero": { "title": "{{ points.sala_temp.text }} na sala", "kicker": "Casa da praia", "greeting": false, "hide": false }
  #
  # `title` e `kicker` aceitam Liquid (o das automações, com limite); sem eles,
  # o título é a saudação (na primeira visão do Início, ou em qualquer visão
  # com `greeting: true`; `false` desliga) ou o nome da visão, e a linha de
  # cima é "local · data". `hide: true` tira o topo (quiosque, painel de
  # parede). O servidor resolve tudo em `hero_now` ({title, kicker, hide})
  # para a web e o app; Liquid com erro mostra o texto cru.
  module Hero
    KEYS = %w[title kicker greeting hide].freeze
    MAX = 200

    module_function

    def errors(hero)
      return [ I18n.t("dashboards.hero.errors.object") ] unless hero.is_a?(Hash)

      e = []
      e << I18n.t("dashboards.hero.errors.unknown", keys: KEYS.join(", ")) unless (hero.keys - KEYS).empty?
      %w[greeting hide].each { |k| e << I18n.t("dashboards.hero.errors.bool", key: k) if hero.key?(k) && ![ true, false ].include?(hero[k]) }
      %w[title kicker].each do |k|
        next unless hero.key?(k)
        next e << I18n.t("dashboards.hero.errors.text", key: k, max: MAX) unless hero[k].is_a?(String) && hero[k].size <= MAX

        Liquid::Template.parse(hero[k], error_mode: :strict)
      rescue Liquid::Error => ex
        e << I18n.t("dashboards.hero.errors.liquid", key: k, error: ex.message.truncate(120))
      end
      e
    end

    # Põe `hero_now` em cada visão do painel resolvido (web e API). `home`: é o Início da pessoa.
    def apply!(payload, site:, user:, home: true)
      views = Array(payload["views"])
      views.each_with_index { |v, i| v["hero_now"] = resolve(v, site: site, user: user, greet: home && i.zero?) }
      payload
    end

    def resolve(view, site:, user:, greet: false)
      hero = view["hero"].is_a?(Hash) ? view["hero"] : {}
      return { "hide" => true } if hero["hide"] == true

      now = Time.current.in_time_zone(site.timezone)
      title = render(hero["title"], site)
      title ||= greeting(now, user) if hero["greeting"] == true || (hero["greeting"].nil? && greet)
      { "title" => title || view["title"].to_s,
        "kicker" => render(hero["kicker"], site) || [ site.name, I18n.l(now.to_date, format: :long) ].join(" · ") }
    end

    def greeting(now, user)
      part = %w[morning afternoon evening][now.hour < 12 ? 0 : (now.hour < 18 ? 1 : 2)]
      [ I18n.t("greeting.#{part}"), user&.name.to_s.split.first ].compact_blank.join(", ")
    end

    def render(text, site)
      return nil if text.blank?
      return text unless text.include?("{{") || text.include?("{%")

      Automations::Context.new(site: site).render(text, limit: MAX).presence
    rescue Automations::Context::Error
      text
    end
  end
end
