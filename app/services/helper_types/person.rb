module HelperTypes
  # Pessoa (person do HA): ligada (ou não) a um usuário e a várias fontes de
  # rastreio em ordem de prioridade (`address.sources`). O valor é o nome da
  # zona onde está ou "Fora". Cada fonte é lida pelo rastreador que se aplica
  # a ela (People::TRACKERS); vale a primeira fonte, na ordem, que diz em
  # qual zona a pessoa está; nenhuma = "Fora" se alguma disse fora, senão
  # fica sem sinal. Fonte sem sinal (qualidade ruim) não conta.
  #
  # Privacidade: a pessoa guarda só a zona e o nome da fonte que decidiu,
  # nunca coordenadas (essas ficam no ponto do celular, com retenção).
  class Person < Plugin
    MAX_SOURCES = 10

    describe key: "person", title: "Pessoa", icon: "user-circle", capability: "enum",
             description: "Quem está em casa ou em outra zona, pelo celular (GPS, Wi-Fi) e pela rede. Vários rastreadores, com prioridade."
    MAX_AWAY_DELAY_S = 3600
    fields [ :user_id, :home_ssids, :away_delay_min, { sources: [] } ]
    texts "pt-BR" => { no_source: "Escolha ao menos uma fonte de rastreio.", no_tracker: "Fonte sem rastreador: %{names}.",
                       user: "Usuário não é desta instalação.", sources: "%{n} fonte(s)", via: "agora por %{source}" },
          en: { title: "Person", description: "Who is home or in another zone, from the phone (GPS, Wi-Fi) and the network. Several trackers, by priority.",
                no_source: "Choose at least one tracking source.", no_tracker: "Source without a tracker: %{names}.",
                user: "This user doesn't belong to this installation.", sources: "%{n} source(s)", via: "now via %{source}" },
          es: { title: "Persona", description: "Quién está en casa o en otra zona, por el celular (GPS, Wi-Fi) y por la red. Varios rastreadores, con prioridad.",
                no_source: "Elige al menos una fuente de rastreo.", no_tracker: "Fuente sin rastreador: %{names}.",
                user: "El usuario no es de esta instalación.", sources: "%{n} fuente(s)", via: "ahora por %{source}" }

    def self.assign(point, form)
      point.writable = false
      point.data_type = "enum"
      ids = Array(form["sources"]).compact_blank.uniq.first(MAX_SOURCES)
      found = point.site.points.where(id: ids).index_by(&:id)
      sources = ids.filter_map { |id| found[id] }
      point.errors.add(:base, text(:no_source)) if sources.empty?
      point.errors.add(:base, text(:no_tracker, names: sources.reject { |s| People.tracker_for(s) }.map(&:name).join(", "))) unless sources.all? { |s| People.tracker_for(s) }
      user_id = form["user_id"].presence
      point.errors.add(:base, text(:user)) if user_id && !User.exists?(id: user_id)
      ssids = form["home_ssids"].to_s.split(/[,\n]/).map { |s| s.strip.delete('"') }.compact_blank.first(10)
      delay = form.key?("away_delay_min") ? (number(form["away_delay_min"]).to_f * 60).round.clamp(0, MAX_AWAY_DELAY_S) : point.address["away_delay_s"]
      point.address = point.address.merge("sources" => sources.map(&:id), "user_id" => user_id, "home_ssids" => ssids, "away_delay_s" => delay).compact
      point.options = options(point.site)
    end

    def self.sourced? = true
    # Tolerância para sair: o relógio confirma a saída depois de `away_delay_s`.
    def self.clocked? = true
    def self.tick(point, now) = (refresh!(point, now) if point.attrs.to_h["leaving_at"])
    def self.away_delay(person) = person.address["away_delay_s"].to_i
    def self.home_ssids(person) = Array(person.address["home_ssids"]).map { |s| s.to_s.downcase }
    def self.options(site) = People.zones(site).map(&:name).sort + [ People::AWAY ]

    def self.home?(person)
      home = Zone.home_of(People.zones(person.site))
      home.present? && person.value == home.name
    end

    def self.sources(person)
      found = person.site.points.where(id: person.address["sources"]).index_by(&:id)
      Array(person.address["sources"]).filter_map { |id| found[id] }
    end

    def self.refresh!(person, now = Time.current)
      Zone.home(person.site) # a casa existe desde a primeira pessoa
      zones = People.zones(person.site)
      zone, source = locate(person, zones)
      was = person.value
      person.options = options(person.site)
      person.save! if person.options_changed?
      zone, source, leaving_at, at = hold(person, zone, source, now)
      person.report!(zone || person.value, quality: zone ? "good" : "unavailable", at: at)
      attrs = person.attrs.to_h
      src = leaving_at ? attrs["source"] : source&.name # saindo: continua valendo a fonte de antes
      person.report_attrs!(attrs.except("source", "room", "leaving_at").merge("source" => src, "room" => room(person), "leaving_at" => leaving_at&.iso8601).compact)
      zones.each { |z| Zone.refresh!(z) } if person.value != was
    end

    # Tolerância (não "piscar"): sair de uma zona para "Fora" só vale depois de
    # `away_delay_s` dizendo fora; nesse meio a pessoa fica onde estava, com
    # `leaving_at` nos atributos. Chegar e trocar de zona valem na hora.
    # → [zona, fonte, saindo desde, hora da mudança].
    def self.hold(person, zone, source, now)
      delay = away_delay(person)
      current = person.value
      return [ zone, source, nil, now ] unless delay.positive? && zone == People::AWAY && current.present? && current != People::AWAY

      since = Time.zone.parse(person.attrs.to_h["leaving_at"].to_s) rescue nil # rubocop:disable Style/RescueModifier
      since ||= now
      return [ zone, source, nil, since ] if now - since >= delay

      [ current, source, since, now ]
    end

    # Cômodo agora (ESPresense): o da primeira fonte de cômodo que sabe.
    def self.room(person)
      sources(person).each do |s|
        t = People.tracker_for(s)
        r = t.respond_to?(:room) && t.room(s)
        return r if r
      end
      nil
    end

    # → [zona, ponto que decidiu]; [nil, nil] = sem sinal de ninguém.
    def self.locate(person, zones)
      away = nil
      sources(person).each do |s|
        next unless s.quality == "good"

        tracker = People.tracker_for(s) or next
        z = tracker.zone(s, person, zones)
        next if z.nil?
        return [ z, s ] unless z == People::AWAY

        away ||= s
      end
      away ? [ People::AWAY, away ] : [ nil, nil ]
    end

    def self.summary(person)
      user = person.address["user_id"] && User.find_by(id: person.address["user_id"])
      [ user&.name, text(:sources, n: Array(person.address["sources"]).size), person.attrs.to_h["source"]&.then { |s| text(:via, source: s) } ].compact.join(" · ")
    end
  end
end
