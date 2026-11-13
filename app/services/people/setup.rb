module People
  # Assistente "Presença pelo celular" da tela Pessoas: para cada morador do
  # local, em que passo ele está (conta → app no celular → localização
  # ligada → pessoa ligada ao celular) e, no fim, criar a pessoa com as fontes
  # do celular na ordem da confiança. O app já manda a presença; aqui só se
  # junta o que existe. Nada de coordenada: só se a localização já chegou.
  module Setup
    STEPS = %w[account app location person].freeze
    Row = Struct.new(:user, :role, :phones, :location, :person, keyword_init: true) do
      def done = STEPS.take_while { |s| step_done?(s) }

      def step_done?(step)
        case step
        when "account" then true
        when "app" then phones.any?
        when "location" then location.present? && location.reported_at.present?
        when "person" then person.present?
        end
      end

      def next_step = STEPS.find { |s| !step_done?(s) }
      def complete? = next_step.nil?
    end

    module_function

    # Moradores = quem tem papel no local (dono e administrador incluídos), sem os desativados e leitores.
    def rows(site)
      persons = People.persons(site).to_a
      phones = site.devices.where("devices.external_id LIKE 'mobile_app:%'").includes(:points).to_a.group_by { |d| d.address["user_id"] }
      User.where(disabled_at: nil).order(:name).filter_map do |u|
        role = site.role_for(u)
        next if role.nil? || role == "viewer"

        mine = phones.fetch(u.id, [])
        Row.new(user: u, role: role, phones: mine, location: location_point(mine),
                person: persons.find { |p| p.address["user_id"] == u.id })
      end
    end

    # O "Presença" do celular que já recebeu leitura (o mais recente).
    def location_point(phones)
      phones.flat_map(&:points).select { |p| p.device_class == "location" }.max_by { |p| p.reported_at || Time.zone.at(0) }
    end

    # Cria a pessoa do morador com as fontes do celular dele (presença e Wi-Fi), pela confiança.
    # → [ponto, erros].
    def create_person!(site, user)
      row = rows(site).find { |r| r.user.id == user.id } or return [ nil, [ I18n.t("presence.setup.not_resident") ] ]
      return [ row.person, [] ] if row.person

      sources = People.by_confidence(row.phones.flat_map(&:points).select { |p| People.tracker_for(p) })
      point = HelperTypes.build(site, HelperTypes.plugin("person"))
      form = { "name" => user.name.to_s.split.first.presence || user.email, "user_id" => user.id, "sources" => sources.map(&:id),
               "away_delay_min" => (People::AWAY_DELAY_S / 60).to_s }
      HelperTypes.save(point, form) ? [ point.reload, [] ] : [ nil, point.errors.full_messages ]
    end
  end
end
