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
    fields [ :user_id, :home_ssids, { sources: [] } ]

    def self.assign(point, form)
      point.writable = false
      point.data_type = "enum"
      ids = Array(form["sources"]).compact_blank.uniq.first(MAX_SOURCES)
      found = point.site.points.where(id: ids).index_by(&:id)
      sources = ids.filter_map { |id| found[id] }
      point.errors.add(:base, "Escolha ao menos uma fonte de rastreio.") if sources.empty?
      point.errors.add(:base, "Fonte sem rastreador: #{sources.reject { |s| People.tracker_for(s) }.map(&:name).join(', ')}.") unless sources.all? { |s| People.tracker_for(s) }
      user_id = form["user_id"].presence
      point.errors.add(:base, "Usuário não é desta instalação.") if user_id && !User.exists?(id: user_id)
      ssids = form["home_ssids"].to_s.split(/[,\n]/).map { |s| s.strip.delete('"') }.compact_blank.first(10)
      point.address = point.address.merge("sources" => sources.map(&:id), "user_id" => user_id, "home_ssids" => ssids).compact
      point.options = options(point.site)
    end

    def self.sourced? = true
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

    def self.refresh!(person)
      Zone.home(person.site) # a casa existe desde a primeira pessoa
      zones = People.zones(person.site)
      zone, source = locate(person, zones)
      was = person.value
      person.options = options(person.site)
      person.save! if person.options_changed?
      person.report!(zone || person.value, quality: zone ? "good" : "unavailable")
      person.report_attrs!(person.attrs.to_h.except("source").merge("source" => source&.name).compact)
      zones.each { |z| Zone.refresh!(z) } if person.value != was
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
      [ user&.name, "#{Array(person.address['sources']).size} fonte(s)", person.attrs.to_h["source"]&.then { |s| "agora por #{s}" } ].compact.join(" · ")
    end
  end
end
