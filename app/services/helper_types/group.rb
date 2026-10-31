module HelperTypes
  # Grupo (group do HA): junta N pontos do mesmo tipo num valor só. Liga/
  # desliga e sensores: todos ou qualquer um ligado; números: média, mínimo,
  # máximo ou soma. Grupo de liga/desliga recebe comando e repassa a cada
  # membro (cada um com o próprio `Points::Command`, na fila se for aparelho
  # de verdade); o valor do grupo se refaz quando um membro muda.
  class Group < Plugin
    BOOL_MODES = { "any" => "Qualquer um ligado", "all" => "Todos ligados" }.freeze
    NUM_MODES = { "mean" => "Média", "min" => "Mínimo", "max" => "Máximo", "sum" => "Soma" }.freeze
    BOOL_CAPS = %w[onoff contact motion problem tamper].freeze
    NUM_CAPS = %w[measure setpoint dimmer counter].freeze
    MAX_MEMBERS = 50

    describe key: "group", title: "Grupo", icon: "collection", capability: "onoff",
             description: "Junta vários pontos do mesmo tipo: todas as luzes da sala, média das temperaturas."
    fields [ :mode, { members: [] } ]

    def self.assign(point, form)
      ids = Array(form["members"]).compact_blank.uniq.first(MAX_MEMBERS)
      members = point.site.points.where(id: ids).where.not(id: point.id).to_a
      caps = members.map(&:capability).uniq
      return point.errors.add(:base, "Escolha ao menos dois pontos.") if members.size < 2
      return point.errors.add(:base, "Os membros precisam ser do mesmo tipo.") unless caps.one?
      return point.errors.add(:base, "Grupo dentro de grupo não pode.") if members.any? { |m| m.helper == key }

      cap = caps.first
      numeric = NUM_CAPS.include?(cap)
      return point.errors.add(:base, "Esse tipo de ponto não forma grupo.") unless numeric || BOOL_CAPS.include?(cap)

      modes = numeric ? NUM_MODES : BOOL_MODES
      point.capability = numeric ? "measure" : cap
      point.data_type = Point::CAPABILITIES[point.capability]
      point.writable = cap == "onoff"
      point.unit = members.filter_map(&:unit).first if numeric
      point.risk = members.map(&:risk).max_by { |r| Point::RISKS.keys.index(r) }
      point.address = point.address.merge("sources" => members.map(&:id), "mode" => form["mode"].presence_in(modes.keys) || modes.keys.first)
    end

    def self.sourced? = true
    def self.drives_points? = true
    def self.members(point) = point.site.points.where(id: point.address["sources"]).to_a

    def self.refresh!(point)
      values = members(point).select { |m| m.quality == "good" }.map(&:value)
      v = case point.address["mode"]
      when "any" then values.any?(true)
      when "all" then values.any? && values.all?(true)
      else aggregate(point.address["mode"], values.grep(Numeric))
      end
      point.report!(v, quality: values.empty? ? "unavailable" : "good")
    end

    def self.aggregate(mode, nums)
      return if nums.empty?

      { "mean" => nums.sum.to_f / nums.size, "min" => nums.min, "max" => nums.max }.fetch(mode) { nums.sum }.then { |v| v.is_a?(Float) ? v.round(3) : v }
    end

    # Comando no grupo: o mesmo comando em cada membro (alternar vira ligar/desligar para todos).
    def self.execute(point, command, _value)
      target = command == "toggle" ? (point.value ? "off" : "on") : command
      parent = point.commands.where(status: "sent").order(:created_at).last
      errors = members(point).filter_map do |m|
        Points::Command.call(m, target, nil, source: parent&.source || "automation", user: parent&.user,
                                             run: parent&.automation_run_id && AutomationRun.find_by(id: parent.automation_run_id)).error
      rescue Points::Command::Error => e
        "#{m.name}: #{e.message}"
      end
      refresh!(point.reload)
      raise Points::Command::Error.new(:member_failed, errors.join(" · ").truncate(250)) if errors.any?
    end

    def self.summary(point)
      modes = BOOL_MODES.merge(NUM_MODES)
      "#{Array(point.address['sources']).size} pontos · #{modes[point.address['mode']]&.downcase}"
    end
  end
end
