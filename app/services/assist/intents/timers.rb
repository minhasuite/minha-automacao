module Assist
  module Intents
    # Timers por voz (HassStartTimer, HassCancelTimer, HassPauseTimer,
    # HassUnpauseTimer, HassTimerStatus), guardados em AssistTimer: do local
    # e, vindo de um satélite, dele (o aviso de fim toca lá).
    module Timers
      WORD = "(timer|timers|temporizador|temporizadores|cronometro|alarme)".freeze

      # "5 minutos" / "1 h 30 min" no idioma da frase.
      def self.duration_text(sec)
        h, rest = sec.divmod(3600)
        m, s = rest.divmod(60)
        parts = { hours: h, minutes: m, seconds: s }.select { |_, v| v.positive? }.map { |k, v| I18n.t("assist.duration.#{k}", count: v) }
        parts.to_sentence
      end

      # Timers do local (do satélite, se veio de um), filtrados pelo nome ou pela duração dita.
      def self.running(ctx, slots)
        list = ctx.site.then { |s| AssistTimer.running.where(site: s) }
        list = list.where(satellite_id: ctx.satellite.id) if ctx.satellite
        list = list.order(:created_at).to_a
        want = slots["name"].presence or return list

        sec = Assist.seconds(want)
        list.select { |t| sec ? t.duration_s == sec : Assist.clean(t.name.to_s) == Assist.clean(want) }
      end

      class Start < Intent
        describe key: "timer_start", slots: %w[duration name],
                 description: "Cria um timer (ex.: 5 minutos, 1 hora e 30 minutos), com nome opcional.",
                 sentences: { "pt-BR" => [ "[(criar|crie|cria|colocar|coloque|coloca|iniciar|inicie|inicia|definir|defina|ligar|ligue|liga|programar|programe|programa|marcar|marque|marca)] [um] #{WORD} (de|para|por|com) {duration} [(chamado|para|do|da|de) {name}]",
                                           "(me avise|me avisa|me lembre|me lembra|avise|avisa) (em|daqui a|daqui) {duration}" ],
                              "en" => [ "[set|start|create] [a] timer for {duration} [(called|named|for) {name}]", "[set|start|create] [a] {duration} timer [(called|named|for) {name}]",
                                        "remind me in {duration}" ],
                              "es" => [ "[pon|poner|crea|crear|inicia|iniciar|programa|programar] [un] (temporizador|timer|cronometro|alarma) (de|por|para) {duration} [(llamado|para|de) {name}]",
                                        "(avisame|recuerdame) en {duration}" ] }
        texts "pt-BR" => { done: "Timer de %{duration} iniciado.", named: "Timer %{name} de %{duration} iniciado.", slots: { duration: "Duração (ex.: 5 minutos)", name: "Nome do timer (opcional)" } },
              en: { description: "Starts a timer (e.g. 5 minutes, 1 hour and 30 minutes), with an optional name.", done: "%{duration} timer started.",
                    named: "%{name} timer for %{duration} started.", slots: { duration: "Duration (e.g. 5 minutes)", name: "Timer name (optional)" } },
              es: { description: "Crea un temporizador (ej.: 5 minutos, 1 hora y 30 minutos), con nombre opcional.", done: "Temporizador de %{duration} iniciado.",
                    named: "Temporizador %{name} de %{duration} iniciado.", slots: { duration: "Duración (ej.: 5 minutos)", name: "Nombre del temporizador (opcional)" } }

        def self.handle(ctx, slots)
          sec = Assist.seconds(slots["duration"]) or return
          return unless sec.between?(1, AssistTimer::MAX)

          name = slots["name"].present? ? Assist.original(ctx.heard, Assist.clean(slots["name"])) : nil
          AssistTimer.start!(site: ctx.site, seconds: sec, name: name, user: ctx.user, satellite: ctx.satellite)
          duration = Timers.duration_text(sec)
          reply(name ? text(:named, name: name, duration: duration) : text(:done, duration: duration))
        end
      end

      class Cancel < Intent
        describe key: "timer_cancel", slots: %w[name],
                 description: "Cancela timers (pelo nome ou duração; sem nada, todos).",
                 sentences: { "pt-BR" => [ "(cancelar|cancele|cancela|parar|pare|desligar|desligue|desliga) [o|os|todos os] [meu|meus] #{WORD} [(de|do|da|chamado) {name}]" ],
                              "en" => [ "(cancel|stop) [the|my|all] [the|my] (timer|timers) [(for|called|named) {name}]", "(cancel|stop) [the|my] {name} timer" ],
                              "es" => [ "(cancela|cancelar|para|parar|deten|detener) [el|los|todos los|mi|mis] (temporizador|temporizadores|timer|timers) [(de|del|llamado) {name}]" ] }
        texts "pt-BR" => { done: "Cancelei %{count}.", none: "Nenhum timer ativo." },
              en: { description: "Cancels timers (by name or duration; with nothing, all of them).", done: "Cancelled %{count}.", none: "No timers running." },
              es: { description: "Cancela temporizadores (por nombre o duración; sin nada, todos).", done: "Cancelé %{count}.", none: "No hay temporizadores activos." }

        def self.handle(ctx, slots)
          list = Timers.running(ctx, slots)
          return reply(text(:none)) if list.empty?

          list.each(&:cancel!)
          reply(text(:done, count: I18n.t("assist.timers", count: list.size)))
        end
      end

      class Pause < Intent
        describe key: "timer_pause", slots: %w[name],
                 description: "Pausa timers.",
                 sentences: { "pt-BR" => [ "(pausar|pause|pausa) [o|os] #{WORD} [(de|do|da|chamado) {name}]" ],
                              "en" => [ "pause [the|my] (timer|timers) [(for|called|named) {name}]" ],
                              "es" => [ "(pausa|pausar) [el|los] (temporizador|temporizadores|timer) [(de|del|llamado) {name}]" ] }
        texts "pt-BR" => { done: "Pausei %{count}.", none: "Nenhum timer contando." },
              en: { description: "Pauses timers.", done: "Paused %{count}.", none: "No timers running." },
              es: { description: "Pausa temporizadores.", done: "Pausé %{count}.", none: "No hay temporizadores en marcha." }

        def self.handle(ctx, slots)
          list = Timers.running(ctx, slots).select { |t| t.status == "active" }
          return reply(text(:none)) if list.empty?

          list.each(&:pause!)
          reply(text(:done, count: I18n.t("assist.timers", count: list.size)))
        end
      end

      class Resume < Intent
        describe key: "timer_resume", slots: %w[name],
                 description: "Continua timers pausados.",
                 sentences: { "pt-BR" => [ "(continuar|continue|continua|retomar|retome|retoma|despausar|despause) [o|os] #{WORD} [(de|do|da|chamado) {name}]" ],
                              "en" => [ "(resume|unpause|continue) [the|my] (timer|timers) [(for|called|named) {name}]" ],
                              "es" => [ "(reanuda|reanudar|continua|continuar) [el|los] (temporizador|temporizadores|timer) [(de|del|llamado) {name}]" ] }
        texts "pt-BR" => { done: "Continuei %{count}.", none: "Nenhum timer pausado." },
              en: { description: "Resumes paused timers.", done: "Resumed %{count}.", none: "No paused timers." },
              es: { description: "Reanuda temporizadores en pausa.", done: "Reanudé %{count}.", none: "No hay temporizadores en pausa." }

        def self.handle(ctx, slots)
          list = Timers.running(ctx, slots).select { |t| t.status == "paused" }
          return reply(text(:none)) if list.empty?

          list.each(&:resume!)
          reply(text(:done, count: I18n.t("assist.timers", count: list.size)))
        end
      end

      class Status < Intent
        describe key: "timer_status", slots: %w[name],
                 description: "Diz quanto falta em cada timer.",
                 sentences: { "pt-BR" => [ "quanto [tempo] falta [(no|para o|pro|do)] [#{WORD}] [(de|do|da|chamado) {name}]", "(status|estado) [do|dos] #{WORD}", "como (esta|estao) [o|os] #{WORD}" ],
                              "en" => [ "how (much time|long) is left [on [the|my] (timer|timers)]", "[what is the] (timer|timers) status", "how are [the|my] timers" ],
                              "es" => [ "cuanto [tiempo] (falta|queda) [en el|del] [temporizador]", "estado [del|de los] (temporizador|temporizadores)" ] }
        texts "pt-BR" => { left: "%{name}: faltam %{left}", paused: "%{name}: pausado, faltam %{left}", none: "Nenhum timer ativo.", timer: "Timer de %{duration}" },
              en: { description: "Tells how much time is left on each timer.", left: "%{name}: %{left} left", paused: "%{name}: paused, %{left} left",
                    none: "No timers running.", timer: "%{duration} timer" },
              es: { description: "Dice cuánto falta en cada temporizador.", left: "%{name}: faltan %{left}", paused: "%{name}: en pausa, faltan %{left}",
                    none: "No hay temporizadores activos.", timer: "Temporizador de %{duration}" }

        def self.handle(ctx, slots)
          list = Timers.running(ctx, slots)
          return reply(text(:none)) if list.empty?

          lines = list.first(5).map do |t|
            name = t.name.presence || text(:timer, duration: Timers.duration_text(t.duration_s))
            text(t.status == "paused" ? :paused : :left, name: name, left: Timers.duration_text([ t.remaining, 1 ].max))
          end
          reply("#{lines.join('. ')}.")
        end
      end
    end
  end
end
