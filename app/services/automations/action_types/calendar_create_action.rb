module Automations
  module ActionTypes
    # "Criar evento na agenda" (ondaA1, A11; o `calendar.create_event` do
    # HA): numa agenda local, com título e início em texto (Liquid aceito) e
    # a duração. Segurada em sombra só se a agenda for de fora (local é
    # interna: roda).
    class CalendarCreateAction < Base
      describe key: "calendar_create", label: "Criar evento na agenda", defaults: { "duration" => "1h" },
               fields: [ f("point", :point, "Agenda local", required: true, en: "Local calendar", es: "Agenda local"),
                         f("summary", :template, "Título", required: true, en: "Title", es: "Título"),
                         f("start", :template, "Início (AAAA-MM-DD HH:MM; vazio = agora)", en: "Start (YYYY-MM-DD HH:MM; blank = now)", es: "Inicio (AAAA-MM-DD HH:MM; vacío = ahora)"),
                         f("duration", :duration, "Duração", en: "Duration", es: "Duración"),
                         f("all_day", :bool, "Dia todo", en: "All day", es: "Todo el día") ]
      texts "pt-BR" => { local: "escolha uma agenda local (helper Agenda local).", title: "Criar evento: %{summary}" },
            en: { label: "Create calendar event", local: "choose a local calendar (Local calendar helper).", title: "Create event: %{summary}" },
            es: { label: "Crear evento en la agenda", local: "elige una agenda local (helper Agenda local).", title: "Crear evento: %{summary}" }

      def self.shadow_safe?(_e, _node) = true

      def self.call(e, _path, node)
        cal = e.ctx.point(node["point"])
        raise Engine::Failure, text(:local) unless cal&.helper == HelperTypes::LocalCalendar.key

        summary = e.ctx.render(node["summary"])
        start_text = e.ctx.render(node["start"].to_s).presence
        start = start_text ? HelperTypes::LocalCalendar.parse(start_text, e.ctx.now.time_zone) : e.ctx.now
        stop = start && start + Dsl.seconds(node["duration"] || "1h").to_i
        title = text(:title, summary: summary)
        return [ title, "simulated", start&.iso8601 ] if e.dry_run?

        ev = HelperTypes::LocalCalendar.add_event!(cal, "summary" => summary, "start" => start, "end" => stop, "all_day" => node["all_day"] == true)
        [ title, "ok", ev["start"] ]
      rescue ArgumentError => ex
        raise Engine::Failure, ex.message
      end
    end
  end
end
