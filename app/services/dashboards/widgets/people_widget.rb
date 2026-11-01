module Dashboards
  module Widgets
    # Pessoas (Pacote 3; o cartão de pessoas do HA): quem está em casa, em
    # outra zona ou fora, desde quando. Sem `bind`: todas as pessoas do local
    # (helpers Pessoa); `params.zone` (nome) mostra só quem está nessa zona.
    class PeopleWidget < Base
      describe type: "people", label: "Pessoas", icon: "users", params: %w[zone]

      def self.data(r, w, _binds)
        persons = People.persons(r.site).to_a
        persons = persons.select { |p| p.value == w["zone"] } if w["zone"].present?
        persons.each { |p| r.use(p) }
        home = HelperTypes::Zone.home_of(People.zones(r.site))&.name
        list = persons.map do |p|
          { "id" => p.id, "name" => p.name, "zone" => p.value, "home" => p.value.present? && p.value == home,
            "since" => p.changed_at&.iso8601, "quality" => p.quality, "initials" => initials(p.name) }
        end
        [ { "point_ids" => persons.map(&:id), "people" => list, "home_count" => list.count { |x| x["home"] } }, persons ]
      end

      def self.initials(name) = name.to_s.split.first(2).map { |s| s[0] }.join.upcase
    end
  end
end
