module HelperTypes
  # Grupo (group do HA): junta N pontos do mesmo tipo num valor só. Liga/
  # desliga e sensores: todos ou qualquer um ligado; números: média, mínimo,
  # máximo ou soma. Grupo de liga/desliga recebe comando e repassa a cada
  # membro (cada um com o próprio `Points::Command`, na fila se for aparelho
  # de verdade); o valor do grupo se refaz quando um membro muda.
  class Group < Plugin
    BOOL_MODES = { "any" => "Qualquer um ligado", "all" => "Todos ligados" }.freeze
    NUM_MODES = { "mean" => "Média", "median" => "Mediana", "min" => "Mínimo", "max" => "Máximo", "sum" => "Soma" }.freeze
    BOOL_CAPS = %w[onoff contact motion problem tamper].freeze
    NUM_CAPS = %w[measure setpoint dimmer counter].freeze
    # ondaC2 (C9): grupo de players (o media_player group do HA): o comando vai a todos; o valor é o do que estiver tocando.
    MEDIA_CAPS = %w[media].freeze
    MEDIA_FAN = %w[on off resume pause next previous volume volume_up volume_down mute play_media].freeze
    MAX_MEMBERS = 50

    describe key: "group", title: "Grupo", icon: "collection", capability: "onoff",
             description: "Junta vários pontos do mesmo tipo: todas as luzes da sala, média das temperaturas."
    fields [ :mode, { members: [] } ]
    texts "pt-BR" => { modes: BOOL_MODES.merge(NUM_MODES), two: "Escolha ao menos dois pontos.", same: "Os membros precisam ser do mesmo tipo.",
                       nested: "Grupo dentro de grupo não pode.", kind: "Esse tipo de ponto não forma grupo.", summary: "%{n} pontos · %{mode}" },
          en: { title: "Group", description: "Combines several points of the same type: all living room lights, average temperature.",
                modes: { any: "Any one on", all: "All on", mean: "Average", median: "Median", min: "Minimum", max: "Maximum", sum: "Sum" },
                two: "Choose at least two points.", same: "Members must be of the same type.", nested: "A group can't contain another group.",
                kind: "This type of point can't be grouped.", summary: "%{n} points · %{mode}" },
          es: { title: "Grupo", description: "Junta varios puntos del mismo tipo: todas las luces de la sala, promedio de las temperaturas.",
                modes: { any: "Cualquiera encendido", all: "Todos encendidos", mean: "Promedio", median: "Mediana", min: "Mínimo", max: "Máximo", sum: "Suma" },
                two: "Elige al menos dos puntos.", same: "Los miembros deben ser del mismo tipo.", nested: "Un grupo no puede estar dentro de otro grupo.",
                kind: "Este tipo de punto no forma grupo.", summary: "%{n} puntos · %{mode}" }

    def self.bool_modes = labels(:modes, BOOL_MODES)
    def self.num_modes = labels(:modes, NUM_MODES)

    def self.assign(point, form)
      ids = Array(form["members"]).compact_blank.uniq.first(MAX_MEMBERS)
      members = point.site.points.where(id: ids).where.not(id: point.id).to_a
      caps = members.map(&:capability).uniq
      return point.errors.add(:base, text(:two)) if members.size < 2
      return point.errors.add(:base, text(:same)) unless caps.one?
      return point.errors.add(:base, text(:nested)) if members.any? { |m| m.helper == key }

      cap = caps.first
      numeric = NUM_CAPS.include?(cap)
      media = MEDIA_CAPS.include?(cap)
      return point.errors.add(:base, text(:kind)) unless numeric || media || BOOL_CAPS.include?(cap)

      modes = numeric ? NUM_MODES : BOOL_MODES
      point.capability = numeric ? "measure" : cap
      point.data_type = Point::CAPABILITIES[point.capability]
      point.writable = cap == "onoff" || media
      point.unit = members.filter_map(&:unit).first if numeric
      point.risk = members.map(&:risk).max_by { |r| Point::RISKS.keys.index(r) }
      point.address = point.address.merge("sources" => members.map(&:id), "mode" => form["mode"].presence_in(modes.keys) || modes.keys.first)
    end

    def self.sourced? = true
    def self.drives_points? = true
    def self.members(point) = point.site.points.where(id: point.address["sources"]).to_a

    def self.refresh!(point)
      values = members(point).select { |m| m.quality == "good" }.map(&:value)
      return point.report!(media_value(values), quality: values.empty? ? "unavailable" : "good") if point.capability == "media"

      v = case point.address["mode"]
      when "any" then values.any?(true)
      when "all" then values.any? && values.all?(true)
      else aggregate(point.address["mode"], values.grep(Numeric))
      end
      point.report!(v, quality: values.empty? ? "unavailable" : "good")
    end

    def self.media_value(values)
      hashes = values.grep(Hash)
      hashes.find { |v| v["state"] == "playing" } || hashes.find { |v| v["state"].in?(%w[paused on]) } || hashes.first || { "state" => "idle" }
    end

    def self.commands(point) = point.capability == "media" ? MEDIA_FAN : super

    def self.aggregate(mode, nums)
      return if nums.empty?

      sorted = nums.sort
      median = (sorted[(sorted.size - 1) / 2] + sorted[sorted.size / 2]) / 2.0
      { "mean" => nums.sum.to_f / nums.size, "median" => median, "min" => nums.min, "max" => nums.max }.fetch(mode) { nums.sum }.then { |v| v.is_a?(Float) ? v.round(3) : v }
    end

    # Comando no grupo: o mesmo comando em cada membro (alternar vira ligar/desligar para todos).
    def self.execute(point, command, value)
      target = command == "toggle" ? (point.value ? "off" : "on") : command
      value = nil unless point.capability == "media"
      parent = point.commands.where(status: "sent").order(:created_at).last
      errors = members(point).filter_map do |m|
        next if point.capability == "media" && !Points::Command.commands_for(m).include?(target) # player do grupo que não faz isso (TV sem volume exato)

        Points::Command.call(m, target, value, source: parent&.source || "automation", user: parent&.user,
                                             run: parent&.automation_run_id && AutomationRun.find_by(id: parent.automation_run_id)).error
      rescue Points::Command::Error => e
        "#{m.name}: #{e.message}"
      end
      refresh!(point.reload)
      raise Points::Command::Error.new(:member_failed, errors.join(" · ").truncate(250)) if errors.any?
    end

    def self.summary(point)
      mode = point.address["mode"]
      text(:summary, n: Array(point.address["sources"]).size, mode: (text("modes.#{mode}").downcase if mode))
    end
  end
end
