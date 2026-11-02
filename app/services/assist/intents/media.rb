module Assist
  module Intents
    # Mídia (HassMediaPause, HassMediaUnpause, HassMediaNext,
    # HassMediaPrevious, HassSetVolume, HassMediaSearchAndPlay). Sem nome: o
    # que está tocando (ou pausado, para continuar), o da área do satélite ou,
    # se houver um só, ele.
    module Media
      ON = "[(na|no|da|do|em) {name}]".freeze
      ON_EN = "[(on|in) [the] {name}]".freeze
      ON_ES = "[(en|del|de la) {name}]".freeze

      class Base < Intent
        def self.capabilities = %w[media]
        def self.command = nil
        def self.prefer = "playing"
        def self.value(_slots) = nil

        def self.handle(ctx, slots)
          points = slots["name"].present? ? Assist.targets(ctx, slots["name"], capabilities, command: command) : idle(ctx)
          return if points.empty?

          run(ctx, points, command, value(slots), done: :done, **vars(slots))
        end

        def self.vars(_slots) = {}

        def self.idle(ctx)
          all = Assist.targets(ctx, nil, capabilities, command: command)
          by_state = all.select { |p| p.value.is_a?(Hash) && p.value["state"] == prefer }
          return by_state if by_state.any?

          here = ctx.area ? all.select { |p| ctx.area.subtree_ids.include?(p.effective_area_id) } : []
          here.presence || (all.one? ? all : [])
        end
      end

      class Pause < Base
        describe key: "media_pause", slots: %w[name],
                 description: "Pausa o que está tocando (TV, caixa de som, Spotify...).",
                 sentences: { "pt-BR" => [ "(pausar|pause|pausa) [a musica|o video|o filme|a tv|o som] #{ON}" ],
                              "en" => [ "pause [the] [music|song|video|movie|tv] #{ON_EN}" ],
                              "es" => [ "(pausa|pausar|pausar) [la musica|el video|la pelicula|la tele] #{ON_ES}" ] }
        texts "pt-BR" => { done: "Pausei %{names}." },
              en: { description: "Pauses what is playing (TV, speaker, Spotify...).", done: "Paused %{names}." },
              es: { description: "Pausa lo que está sonando (TV, altavoz, Spotify...).", done: "Pausé %{names}." }

        def self.command = "pause"
      end

      class Resume < Base
        describe key: "media_resume", slots: %w[name],
                 description: "Continua o que estava pausado.",
                 sentences: { "pt-BR" => [ "(continuar|continue|continua|retomar|retome|retoma|despausar|despause) [a musica|o video|o filme|a tv|o som] #{ON}" ],
                              "en" => [ "(resume|unpause|continue) [the] [music|song|video|movie|tv] #{ON_EN}" ],
                              "es" => [ "(continua|continuar|reanuda|reanudar|sigue) [la musica|el video|la pelicula] #{ON_ES}" ] }
        texts "pt-BR" => { done: "Continuei %{names}." },
              en: { description: "Resumes what was paused.", done: "Resumed %{names}." },
              es: { description: "Continúa lo que estaba en pausa.", done: "Reanudé %{names}." }

        def self.command = "resume"
        def self.prefer = "paused"
      end

      class Next < Base
        describe key: "media_next", slots: %w[name],
                 description: "Pula para a próxima faixa.",
                 sentences: { "pt-BR" => [ "(proxima|pular|pule|pula|avancar|avance|avanca) [a] [musica|faixa|cancao] [proxima] #{ON}" ],
                              "en" => [ "(next|skip) [the|this] [song|track] #{ON_EN}", "play the next (song|track) #{ON_EN}" ],
                              "es" => [ "(siguiente|salta|saltar|pasa|pasar) [la] [cancion|pista] [siguiente] #{ON_ES}" ] }
        texts "pt-BR" => { done: "Próxima em %{names}." },
              en: { description: "Skips to the next track.", done: "Next track on %{names}." },
              es: { description: "Pasa a la siguiente pista.", done: "Siguiente en %{names}." }

        def self.command = "next"
      end

      class Previous < Base
        describe key: "media_previous", slots: %w[name],
                 description: "Volta para a faixa anterior.",
                 sentences: { "pt-BR" => [ "(voltar|volte|volta) [a|para a] (musica|faixa) [anterior] #{ON}", "(musica|faixa) anterior #{ON}" ],
                              "en" => [ "previous (song|track) #{ON_EN}", "(go back|play the previous) [song|track] #{ON_EN}" ],
                              "es" => [ "(cancion|pista) anterior #{ON_ES}", "(vuelve|volver) a la (cancion|pista) anterior #{ON_ES}" ] }
        texts "pt-BR" => { done: "Voltei a faixa em %{names}." },
              en: { description: "Goes back to the previous track.", done: "Previous track on %{names}." },
              es: { description: "Vuelve a la pista anterior.", done: "Pista anterior en %{names}." }

        def self.command = "previous"
      end

      class Volume < Base
        describe key: "media_volume", slots: %w[name volume], numbers: %w[volume],
                 description: "Ajusta o volume (0 a 100).",
                 sentences: { "pt-BR" => [ "[(colocar|coloque|coloca|ajustar|ajuste|ajusta|mudar|mude|muda|por|ponha|deixar|deixe|deixa) o] volume #{ON} (em|para|no|a) {volume} [%|por cento]" ],
                              "en" => [ "[set|change|turn] [the] volume #{ON_EN.sub('(on|in)', '(on|in|of)')} to {volume} [%|percent]" ],
                              "es" => [ "[pon|poner|ajusta|ajustar|cambia|deja] [el] volumen #{ON_ES} (a|al|en) {volume} [%|por ciento]" ] }
        texts "pt-BR" => { done: "Volume de %{names} em %{value}.", slots: { volume: "Volume de 0 a 100" } },
              en: { description: "Sets the volume (0 to 100).", done: "%{names} volume set to %{value}.", slots: { volume: "Volume from 0 to 100" } },
              es: { description: "Ajusta el volumen (0 a 100).", done: "Volumen de %{names} en %{value}.", slots: { volume: "Volumen de 0 a 100" } }

        def self.capabilities = %w[media speaker]
        def self.command = "volume"
        def self.value(slots) = Assist.number(slots["volume"])&.round&.clamp(0, 100)
        def self.vars(slots) = { value: value(slots) }
        def self.handle(ctx, slots) = value(slots) && super
      end

      class Play < Base
        describe key: "media_play", slots: %w[name query],
                 description: "Toca uma música, playlist, artista ou endereço numa mídia.",
                 sentences: { "pt-BR" => [ "(tocar|toque|toca|reproduzir|reproduza|reproduz) {query} (na|no|em) {name}", "(tocar|toque|toca|reproduzir|reproduza) {query}" ],
                              "en" => [ "play {query} (on|in) [the] {name}", "play {query}" ],
                              "es" => [ "(pon|reproduce|reproducir|toca|tocar) {query} en [el|la] {name}", "(reproduce|reproducir|toca|tocar) {query}" ] }
        texts "pt-BR" => { done: "Tocando %{query} em %{names}.", slots: { query: "O que tocar" } },
              en: { description: "Plays a song, playlist, artist or address on a media player.", done: "Playing %{query} on %{names}.",
                    slots: { query: "What to play" } },
              es: { description: "Reproduce una canción, lista, artista o dirección en un reproductor.", done: "Reproduciendo %{query} en %{names}.",
                    slots: { query: "Qué reproducir" } }

        def self.command = "play_media"
        def self.prefer = "on"
        def self.value(slots) = slots["query"].to_s.strip.presence
        def self.vars(slots) = { query: value(slots) }
        def self.handle(ctx, slots) = value(slots) && super(ctx, slots.merge("query" => Assist.original(ctx.heard, slots["query"].to_s)))
      end
    end
  end
end
