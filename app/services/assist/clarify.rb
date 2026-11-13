module Assist
  # "Qual delas?": pedido no singular ("desligue a luz do escritório") que
  # casa com vários pontos pelo tipo ou por parte do nome não executa; a casa
  # lista e guarda o pedido por PENDING_TTL. A próxima frase da mesma
  # conversa (ou da mesma pessoa/satélite, quando o cliente não manda
  # conversa) escolhe: parte do nome ("a do teto", "monitor 1"), a ordem
  # ("a segunda", "2"), "todas" ou "cancela". Outra frase qualquer descarta a
  # pergunta e segue como pedido novo. Plural ("as luzes"), cômodo inteiro e
  # nome exato não perguntam. Nada aqui comanda: quem executa é o `run` da
  # própria intenção, com o papel x risco de sempre.
  module Clarify
    PENDING_TTL = 60
    MAX_LIST = 5
    PLURAL = %w[todas todos todo toda as os ambas ambos all every both las los].freeze
    ALL = %w[todas todos ambas ambos tudo all both every todo toda].freeze
    CANCEL = %w[cancela cancelar cancele nenhuma nenhum nada deixa esquece cancel nevermind none nothing ninguna ninguno olvidalo].freeze
    ORDINALS = { "primeira" => 1, "primeiro" => 1, "first" => 1, "segunda" => 2, "segundo" => 2, "second" => 2, "terceira" => 3, "terceiro" => 3,
                 "third" => 3, "tercera" => 3, "tercero" => 3, "quarta" => 4, "quarto" => 4, "fourth" => 4, "cuarta" => 4, "cuarto" => 4,
                 "quinta" => 5, "quinto" => 5, "fifth" => 5, "ultima" => -1, "ultimo" => -1, "last" => -1 }.freeze
    FILLER = %w[a o as os da do de das dos na no e que the one la el del en uma um numero number opcao].freeze

    module_function

    def key(site, conversation_id, user, satellite)
      who = conversation_id.presence || (user && "u#{user.id}") || (satellite && "s#{satellite.id}") or return nil
      "assist:clarify:#{site.id}:#{who}"
    end

    # Singular, várias opções e casou pelo tipo ou por parte do nome.
    def ask?(phrase, how, points)
      return false unless points.size > 1 && how.in?(%i[kind words])

      words = Assist.normalize(phrase).split
      return false if words.intersect?(PLURAL)

      first = words.find { |w| !w.in?(FILLER) }
      first.nil? || Assist.stem(first) == first
    end

    def ask(ctx, intent, points, command, value = nil)
      return intent.send(:run, ctx, points, command, value, done: :done) unless ctx.pending_key

      Rails.cache.write(ctx.pending_key, { "intent" => intent.key, "command" => command, "value" => value, "points" => points.map(&:id) },
                        expires_in: PENDING_TTL)
      names = labels(points)
      text = if names.size > MAX_LIST
        I18n.t("assist.clarify.many", n: names.size, names: Assist.list(names.first(MAX_LIST)))
      else
        I18n.t("assist.clarify.which", n: names.size, names: Assist.list(names))
      end
      Reply.new(text: text, intent: "clarify", points: [])
    end

    # Resposta à pergunta pendente → Reply, ou nil (não há pergunta, ou a frase
    # não escolhe nada: a pergunta fica e o Assist tenta como pedido novo).
    def answer(ctx, heard)
      loaded = load(ctx) or return nil
      pending, intent, points = loaded
      words = Assist.normalize(heard).split
      if words.intersect?(CANCEL)
        clear(ctx)
        return Reply.new(text: I18n.t("assist.clarify.cancelled"), intent: "clarify", points: [])
      end
      chosen = pick(points, words) or return nil
      return ask(ctx, intent, chosen, pending["command"], pending["value"]) if chosen.size > 1 && chosen.size < points.size

      clear(ctx)
      intent.send(:run, ctx, chosen, pending["command"], pending["value"], done: :done)
    end

    # Nada reconheceu a frase e há pergunta pendente: repete as opções.
    def again(ctx, heard)
      loaded = load(ctx) or return nil
      points = loaded.last
      Reply.new(text: I18n.t("assist.clarify.again", heard: heard, names: Assist.list(labels(points).first(MAX_LIST))), intent: "clarify", points: [])
    end

    def clear(ctx) = ctx.pending_key && Rails.cache.delete(ctx.pending_key)

    def load(ctx)
      pending = ctx.pending_key && Rails.cache.read(ctx.pending_key) or return nil
      intent = Assist.intents.find { |i| i.key == pending["intent"] }
      points = Assist.exposed(ctx.site.points.where(id: pending["points"])).sort_by { |p| pending["points"].index(p.id) }
      return clear(ctx) && nil unless intent && points.any?

      [ pending, intent, points ]
    end

    # Pontos que a resposta escolhe: todos, pela ordem dita ou pelas palavras do nome.
    def pick(points, words)
      return points if words.intersect?(ALL)

      n = words.filter_map { |w| ORDINALS[w] || (w.match?(/\A\d+\z/) && w.to_i) || Assist::WORDS[w] }.first
      if n && words.reject { |w| w.in?(FILLER) || ORDINALS.key?(w) || w.match?(/\A\d+\z/) || Assist::WORDS.key?(w) }.empty?
        p = n == -1 ? points.last : points[n - 1]
        return p && [ p ]
      end

      want = words.reject { |w| w.in?(FILLER) }.map { |w| Assist.stem(w) }
      return nil if want.empty?

      found = points.select do |p|
        have = Assist.normalize([ p.name, *p.aliases, p.device&.name ].compact.join(" ")).split.map { |w| Assist.stem(w) }
        want.all? { |w| have.include?(w) }
      end
      found.presence
    end

    # Nome repetido ("Liga/desliga") vai com o aparelho.
    def labels(points)
      counts = points.map(&:name).tally
      points.map { |p| counts[p.name] > 1 && p.device ? "#{p.name} (#{p.device.name})" : p.name }
    end
  end
end
