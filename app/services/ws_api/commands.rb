module WsApi
  # Comandos que vêm com o produto (mesmos nomes do HA quando há equivalente).
  module Commands
    class Ping < Command
      describe type: "ping"
      def self.call(_ctx, _msg) = "pong"
    end

    # Quem é e os locais que pode ver.
    class GetConfig < Command
      describe type: "get_config"

      def self.call(ctx, _msg)
        { "user" => { "id" => ctx.user.id, "name" => ctx.user.name },
          "sites" => ctx.sites.map { |s| { "id" => s.id, "name" => s.name, "role" => s.role_for(ctx.user), "time_zone" => Time.zone.tzinfo.name } },
          "version" => Updates.current_tag, "commands" => WsApi.commands.map(&:type) }
      end
    end

    # Estado dos pontos de um local (como o get_states do HA; até 2000).
    class GetStates < Command
      describe type: "get_states"

      def self.call(ctx, msg)
        site = ctx.site(msg["site_id"])
        ctx.tenant { site.points.where(disabled: false).includes(:device).order(:key).limit(2000).map { |p| WsApi.state(p) } }
      end
    end

    # Comandos aceitos por ponto (o get_services do HA).
    class GetCommands < Command
      describe type: "get_commands"

      def self.call(ctx, msg)
        site = ctx.site(msg["site_id"])
        ctx.tenant { site.points.where(writable: true, disabled: false).order(:key).to_h { |p| [ p.id, Points::Command.commands_for(p) ] } }
      end
    end

    # Comandar um ponto (o call_service do HA), com o papel e o risco do ponto.
    class CallCommand < Command
      describe type: "call_command"

      def self.call(ctx, msg)
        ctx.tenant do
          point = Point.find_by(id: msg["point_id"]) or raise Error.new(:not_found, "point not found")
          role = point.site.role_for(ctx.user)
          raise Error.new(:unauthorized, "not allowed") unless role && role != "viewer" && SiteMembership.allowed?(role, :command, risk: point.risk)

          c = DevTools.command!(point, msg["command"].to_s, msg["value"], user: ctx.user)
          { "command_id" => c.id, "status" => c.status, "error" => c.error }
        end
      end
    end

    # Assinar eventos: `state_changed` (pontos), um evento de automação pelo nome ou "*" (todos).
    class SubscribeEvents < Command
      describe type: "subscribe_events"

      def self.call(ctx, msg)
        site = ctx.site(msg["site_id"])
        ctx.channel.subscribe_events(msg["id"], site, msg["event_type"].presence || "*")
        nil
      end
    end

    class UnsubscribeEvents < Command
      describe type: "unsubscribe_events"

      def self.call(ctx, msg)
        ctx.channel.unsubscribe_events(msg["subscription"]) or raise Error.new(:not_found, "subscription not found")
        nil
      end
    end

    class FireEvent < Command
      describe type: "fire_event"

      def self.call(ctx, msg)
        site = ctx.site(msg["site_id"])
        raise Error.new(:unauthorized, "not allowed") unless SiteMembership.allowed?(site.role_for(ctx.user), :manage)

        { "event_type" => ctx.tenant { DevTools.fire!(site, msg["event_type"], msg["event_data"] || {}) } }
      end
    end

    # Liquid ou expressão no contexto do local (o render_template do HA, de uma vez).
    class RenderTemplate < Command
      describe type: "render_template"

      def self.call(ctx, msg)
        site = ctx.site(msg["site_id"])
        result, error = ctx.tenant { DevTools.render(site, msg["template"].to_s.first(DevTools::MAX_TEMPLATE), mode: msg["mode"] == "expr" ? "expr" : "liquid") }
        raise Error.new(:template_error, error) if error

        result
      end
    end
  end
end
