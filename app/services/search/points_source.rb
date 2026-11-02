module Search
  # Pontos (pelo nome, aparelho ou área). Com verbo ("apagar Sala"), a ação
  # liga/desliga/alterna o ponto que aceita o comando e que o papel comanda;
  # luz em dimmer sem liga/desliga vai a 0 ou 100.
  class PointsSource < Source
    COMMAND = { "off" => "Desligar", "on" => "Ligar", "toggle" => "Alternar" }.freeze
    DIMMER = { "off" => 0, "on" => 100 }.freeze

    def self.call(q, ctx)
      return [] if q.verb == "activate"

      areas = Area.where(site_id: ctx.site_ids).pluck(:id, :name).to_h
      Point.where(site_id: ctx.site_ids, hidden: false, disabled: false).includes(:device).order(:name).limit(2000)
           .select { |p| match?(q, p.name, p.device.name, areas[p.effective_area_id], *p.aliases) }
           .then { |list| q.verb ? list.select { |p| command(p, q.verb) } : list }
           .first(LIMIT).map { |p| result(p, q, ctx, areas) }
    end

    # Dimmer de luz (pela regra de nome do painel automático); cortina não "apaga".
    def self.light?(p) = p.capability == "dimmer" && "#{p.name} #{p.device.name}".match?(Dashboards::Generator::LIGHT)

    # [comando, valor] para o verbo, ou nil se o ponto não faz.
    def self.command(p, verb)
      cmds = Points::Command.commands_for(p)
      return [ verb, nil ] if cmds.include?(verb)

      [ "set", DIMMER[verb] ] if light?(p) && cmds.include?("set") && DIMMER.key?(verb)
    end

    def self.result(p, q, ctx, areas)
      title, context = p.display_names
      helpers = ApplicationController.helpers
      action = if q.verb && p.writable && ctx.allowed?(p.site_id, :command, risk: p.risk)
        cmd, value = command(p, q.verb)
        verb = I18n.t("search.commands.#{q.verb}", default: COMMAND[q.verb].to_s)
        { label: verb, url: command_point_path(p), params: { command: cmd, value: value }.compact,
          confirm: (p.confirm.presence || ("#{verb} #{p.name}?" if p.risk != "normal")),
          confirm_title: (Point::RISKS[p.risk] if p.risk != "normal" || p.confirm.present?) }
      end
      Result.new(kind: I18n.t("search.kinds.point"), title: title, subtitle: [ context, areas[p.effective_area_id], helpers.point_value_text(p) ].compact_blank.uniq.join(" · "),
                 icon: helpers.dw_point_icon(Dashboards::Resolver.point_json(p, ctx.roles[p.site_id])), url: point_path(p), action: action)
    end
  end
end
