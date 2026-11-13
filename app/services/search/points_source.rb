module Search
  # Pontos (pelo nome, aparelho, área ou apelido). Com verbo ("apagar Sala"), a ação
  # liga/desliga/alterna o ponto que aceita o comando e que o papel comanda;
  # luz em dimmer sem liga/desliga vai a 0 ou 100. "ligar a luz da sala" prefere as luzes
  # (etiqueta/nome do painel automático). Câmeras e scripts têm fonte própria.
  class PointsSource < Source
    COMMAND = { "off" => "Desligar", "on" => "Ligar", "toggle" => "Alternar" }.freeze
    DIMMER = { "off" => 0, "on" => 100 }.freeze
    OWN_SOURCE = %w[stream script].freeze # CamerasSource e ScriptsSource

    def self.prefix = "point"

    def self.call(q, ctx)
      return [] if q.verb == "activate"

      areas = areas_for(ctx)
      list = candidates(ctx).reject { |p| OWN_SOURCE.include?(p.capability) }
                            .select { |p| match?(q, p.name, p.device&.name, areas[p.effective_area_id], *p.aliases) }
      list = list.select { |p| command(p, q.verb) } if q.verb
      list = list.select { |p| light?(p, any: true) }.presence || list if q.light
      list.first(CANDIDATES).map { |p| result(p, q, ctx, areas) }
    end

    def self.lookup(id, ctx)
      p = Point.where(site_id: ctx.site_ids, hidden: false, disabled: false).includes(:device).find_by(id: id) or return nil
      result(p, Query.parse(""), ctx, areas_for(ctx))
    end

    # Os pontos dos locais pelo cache curto do painel (já na memória), sem os ocultos/desativados.
    def self.candidates(ctx)
      ctx.sites.flat_map { |s| Dashboards::Cache.points(s) }.select { |p| !p.hidden && !p.disabled }
    end

    def self.areas_for(ctx) = Area.where(site_id: ctx.site_ids).pluck(:id, :name).to_h

    # Dimmer de luz (pela regra de nome do painel automático); cortina não "apaga". `any`: liga/desliga também.
    def self.light?(p, any: false)
      (p.capability == "dimmer" || (any && p.capability == "onoff")) && "#{p.name} #{p.device&.name}".match?(Dashboards::Generator::LIGHT)
    end

    # [comando, valor] para o verbo, ou nil se o ponto não faz.
    def self.command(p, verb)
      cmds = Points::Command.commands_for(p)
      return [ verb, nil ] if cmds.include?(verb)

      [ "set", DIMMER[verb] ] if light?(p) && cmds.include?("set") && DIMMER.key?(verb)
    end

    def self.result(p, q, ctx, areas, kind: I18n.t("search.kinds.point"), icon: nil, key: "point")
      title, context = p.display_names
      helpers = ApplicationController.helpers
      action = api = nil
      if q.verb && p.writable && ctx.allowed?(p.site_id, :command, risk: p.risk) && (cmd = command(p, q.verb))
        verb = I18n.t("search.commands.#{q.verb}", default: COMMAND[q.verb].to_s)
        params = { command: cmd[0], value: cmd[1] }.compact
        confirm = p.confirm.presence || ("#{verb} #{p.name}?" if p.risk != "normal")
        action = { label: verb, url: command_point_path(p), params: params, confirm: confirm,
                   confirm_title: (Point::RISKS[p.risk] if p.risk != "normal" || p.confirm.present?) }
        api = { path: "/points/#{p.id}/commands", body: params.merge(client_uuid: SecureRandom.uuid) }
      end
      Result.new(kind: kind, title: title, subtitle: [ context, areas[p.effective_area_id], helpers.point_value_text(p) ].compact_blank.uniq.join(" · "),
                 icon: icon || helpers.dw_point_icon(Dashboards::Resolver.point_json(p, ctx.roles[p.site_id])), url: point_path(p), action: action, api: api,
                 key: "#{key}:#{p.id}", target: { type: "point", id: p.id, site_id: p.site_id })
    end
  end
end
