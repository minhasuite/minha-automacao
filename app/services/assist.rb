# Voz local (Pacote 3, ondaB1; o Assist do HA): frase (digitada ou transcrita
# pelo STT do pipeline) → intenção local resolvida pelos nomes e apelidos dos
# pontos, áreas e cenas, sem IA, em pt-BR, en e es. Não reconheceu: o agente
# do pipeline decide (Perguntar à casa só leitura, ou a IA com ferramentas,
# Assist::Llm). A resposta é texto e, se pedir, fala (TTS).
#
# Intenção = plugin (Assist::Intent) em `INTENTS`, com frases-modelo por
# idioma no formato do HA (`[opcional]`, `(a|b)`, `{slot}`; Assist::Sentences)
# e `handle(ctx, slots)` → Reply ou nil (não é comigo). A mesma intenção vira
# ferramenta da IA e do servidor MCP. Comando por voz respeita o papel x risco
# de quem fala, a sombra do local e nunca comanda ponto crítico.
module Assist
  INTENTS = %w[
    Conversation Custom Nevermind
    Timers::Start Timers::Cancel Timers::Pause Timers::Resume Timers::Status
    Lists::Add Lists::Complete Lists::Read
    Weather Clock::Time Clock::Date Climate::GetTemperature
    Light::Brightness Light::Color Climate::SetTemperature
    Cover::Open Cover::Close Cover::Position
    Media::Pause Media::Resume Media::Next Media::Previous Media::Volume Media::Play
    Vacuum::Start Vacuum::Dock Broadcast
    OnOff::On OnOff::Off OnOff::Toggle
    State::Is State::Which State::Read Scene
  ].freeze
  LANGUAGES = %w[pt-BR en es].freeze
  MAX_TEXT = 300

  Reply = Data.define(:text, :intent, :points) do
    def initialize(text:, intent:, points: []) = super
  end

  # Quem pergunta, onde (área do satélite) e em que idioma.
  Ctx = Data.define(:site, :user, :role, :heard, :language, :area, :satellite) do
    def initialize(site:, user:, role:, heard: "", language: "pt-BR", area: nil, satellite: nil) = super
  end

  module_function

  def intents = INTENTS.map { |n| Intents.const_get(n) }

  # "pt", "pt_BR", "en-US" → um dos LANGUAGES (o da tela, se não vier).
  def language(raw = nil)
    s = raw.to_s.tr("_", "-").downcase
    LANGUAGES.find { |l| l.downcase == s } || LANGUAGES.find { |l| l[0, 2] == s[0, 2] } || (raw.nil? ? language(I18n.locale) : "pt-BR")
  end

  # → { text:, intent:, heard:, points:, slots:, audio_url? }
  # `agent`: "intents" (só as intenções da casa, sem IA), "local" (padrão:
  # intenções + Perguntar à casa), "local_llm" (intenções e, se não
  # reconhecer, a IA com ferramentas) ou "llm". voz-offline: a IA só entra se
  # for da rede da casa (Ollama) ou se houver internet e `cloud` deixar.
  def call(site:, user:, text:, speak: false, language: nil, area: nil, satellite: nil, agent: "local", llm_provider: nil, conversation_id: nil, cloud: true)
    heard = text.to_s.squish.first(MAX_TEXT)
    raise ArgumentError, I18n.t("assist.empty") if heard.empty?

    lang = language(language || site.language.presence)
    I18n.with_locale(lang) { with_site(site) { answer(site, user, heard, lang, speak:, area:, satellite:, agent:, llm_provider:, conversation_id:, cloud:) } }
  end

  # Um pedido já no idioma e no local da conversa.
  def answer(site, user, heard, lang, speak:, area:, satellite:, agent:, llm_provider:, conversation_id:, cloud: true)
    # ondaB1 (B6): satélite sem pessoa fala com o papel dele.
    ctx = Ctx.new(site: site, user: user, role: user ? site.role_for(user) : satellite&.role, heard: heard, language: lang, area: area || satellite&.area, satellite: satellite)
    reply, slots = agent == "llm" ? [] : recognize(ctx, prepare(heard))
    conversation_id = conversation_id.presence || SecureRandom.uuid if agent.to_s.include?("llm")
    unless reply
      provider = agent == "intents" ? nil : ai_provider(site, llm_provider, structured: agent.to_s.include?("llm"), cloud: cloud)
      reply = if provider.nil? then fallback(ctx, heard, agent)
      elsif conversation_id then Llm.call(ctx, heard, provider: provider, conversation_id: conversation_id)
      else ask(ctx, heard, provider)
      end
    end
    out = { "heard" => heard, "text" => reply.text, "intent" => reply.intent, "points" => reply.points.map(&:id), "language" => lang, "slots" => slots.to_h }
    out["conversation_id"] = conversation_id if conversation_id
    out["audio_url"] = speech(site, reply.text) if speak && reply.text.present?
    out
  end

  # voz-offline: nenhuma intenção reconheceu e a IA não pode responder (agente
  # "intents", IA só da nuvem sem internet ou com a nuvem proibida) → a
  # resposta de "não entendi" da casa, sem esperar a rede.
  def fallback(ctx, heard, agent)
    offline = agent != "intents" && Internet.offline?
    Reply.new(text: Intent.text(offline ? :offline : :not_understood, heard: heard), intent: offline ? "offline" : "unknown")
  end

  # Conta de IA que responde agora (chave do provedor) ou nil: a pedida ou a
  # padrão, se alcançável; senão a primeira da rede da casa (Ollama). A da
  # nuvem só com internet e `cloud`.
  def ai_provider(site, provider = nil, structured: false, cloud: true)
    capability = structured ? :structured : :text
    reachable = ->(a) { a && (a.plugin.local? || (cloud && Internet.online?)) }
    picked = AiAccount.pick(provider, default: Ai::Budget.for(site.tenant).default_provider, capability: capability)
    return picked.provider if reachable.call(picked)
    return if provider.present?

    AiAccount.usable.find { |a| a.plugin.supports?(capability) && a.plugin.local? }&.provider
  end

  # P3: o local da conversa, para as respostas personalizadas (`Intent.text`).
  # Também usado pelo MCP. Guarda as respostas do local uma vez por conversa.
  def with_site(site)
    saved = Thread.current[:assist_site]
    Thread.current[:assist_site] = { site: site, responses: nil }
    yield
  ensure
    Thread.current[:assist_site] = saved
  end

  # Resposta personalizada (intenção ou "*", idioma da conversa ou qualquer) ou nil.
  def custom_response(intent, key)
    state = Thread.current[:assist_site] or return nil
    state[:responses] ||= AssistCustomResponse.where(site_id: state[:site].id).to_a
    lang = I18n.locale.to_s
    found = state[:responses].select { |r| r.text_key == key && [ intent, AssistCustomResponse::ANY ].include?(r.intent) && [ lang, nil ].include?(r.language) }
    found.min_by { |r| [ r.intent == intent ? 0 : 1, r.language ? 0 : 1 ] }
  end

  # Primeira intenção que reconhece a frase e aceita (handle não nil): [Reply, slots].
  # Plugin antigo (só `pattern` em pt) recebe o MatchData.
  def recognize(ctx, norm)
    intents.each do |i|
      slots = i.respond_to?(:match) ? i.match(ctx, norm) : (i.pattern.match(norm) if ctx.language == "pt-BR")
      next unless slots

      reply = i.handle(ctx, slots) and return [ reply, (slots.reject { |k, _| k.start_with?("_") } if slots.is_a?(Hash)) ]
    end
    nil
  end

  # Só reconhecer, sem executar (depuração e teste de frase): [intenção, slots] ou nil.
  def understand(site, text, language: nil)
    lang = language(language || site.language.presence)
    ctx = Ctx.new(site: site, user: nil, role: nil, heard: text.to_s, language: lang)
    norm = prepare(text)
    intents.each do |i|
      next unless i.respond_to?(:match)

      slots = i.match(ctx, norm)
      return [ i, slots.reject { |k, _| k.start_with?("_") } ] if slots && (!i.respond_to?(:accepts?) || i.accepts?(ctx, slots))
    end
    nil
  end

  # Áudio (bytes do microfone) → texto pelo STT da instalação.
  def transcribe(site:, audio:, media_type:, language: "pt", provider: nil)
    res = Ai::Audio.transcribe(tenant: site.tenant, site: site, audio: audio, media_type: media_type, language: language.to_s[0, 2], provider: provider, source: "voz")
    res.data.to_s.dup.force_encoding(Encoding::UTF_8).scrub.squish
  end

  def speech(site, text)
    res = Ai::Audio.speak(tenant: site.tenant, site: site, text: text, source: "voz")
    Ai::Audio.store(res.data[:data], res.data[:media_type], "assistente-#{Time.current.to_i}").last
  rescue Ai::Client::Error => e
    Rails.logger.info("[assist] sem fala: #{e.message}")
    nil
  end

  def ask(ctx, heard, provider = nil)
    Reply.new(text: Ai::Ask.call(site: ctx.site, question: heard, provider: provider), intent: "ask")
  rescue Ai::Client::Error => e
    Reply.new(text: Intent.text(:unknown, error: e.message.truncate(80)), intent: "unknown")
  end

  # Sem acento, minúsculas, sem pontuação.
  # "22,5" fica "22.5" (o ponto só sobrevive entre dígitos).
  def normalize(text)
    I18n.transliterate(text.to_s).downcase.gsub(/(?<=\d)[.,](?=\d)/, "_").gsub(/[^a-z0-9_ ]/, " ").tr("_", ".").squish
  end

  # Artigos e "todos" no começo (pt, en, es) e cortesia no fim.
  STOP = /\A(?:(?:o|a|os|as|do|da|dos|das|de|no|na|nos|nas|em|um|uma|todas?|todos?|the|all|el|la|los|las|del|un|unos|unas|my|meu|minha|mi)\s+)+/
  TAIL = /\s+(?:por favor|agora|pra mim|para mim|please|now|ahora)\z/

  # voz-offline: cortesia, palavra de ativação e "pode..." no começo da frase
  # ("ok casa, pode ligar a luz", "por favor apague", "me diga se a porta está aberta").
  LEAD = /\A(?:(?:ok|ei|oi|hey|ola|alo)\s+(?:casa|google|alexa|assistente)\s+)?(?:(?:por favor|please|pode|podes|poderia|voce pode|voce poderia|consegue|quero que|eu quero|queria|gostaria de|can you|could you|would you|i want to|puedes|podrias|quiero que|quiero|me diga se|me diz se|me fala se|diga se|me diga|me diz|me fala|saber se|tell me if|tell me|dime si|dime)\s+)+/

  # A frase como as intenções a recebem: normalizada e sem a cortesia do começo.
  def prepare(text)
    norm = normalize(text)
    cut = norm.sub(LEAD, "")
    cut.empty? ? norm : cut
  end

  def clean(phrase) = normalize(phrase).sub(TAIL, "").sub(STOP, "").strip
  def stem(word) = word.length > 3 ? word.sub(/ces\z/, "z").sub(/(?:es|s)\z/, "") : word

  # Pontos que a frase nomeia: o nome, o apelido falado (Alexa), "nome da
  # área" ou a área inteira. Exato ganha de "contém". Com a área do satélite,
  # o que estiver nela ganha ("acenda a luz" sem dizer o cômodo).
  def find_points(site, phrase, scope: nil, area: nil)
    want = clean(phrase)
    return [] if want.empty?

    found = match_points(site, want, scope)
    return found unless area && found.size > 1

    here = found.select { |p| area.subtree_ids.include?(p.effective_area_id) }
    here.presence || found
  end

  def match_points(site, want, scope)
    # ondaA1 (A3): só o exposto ao Assist (tela Expor) e os apelidos do ponto e da área.
    points = exposed(scope || site.points)
    names = ->(p) { [ p.name, p.alexa_name, *p.aliases, p.display_names.compact.join(" "), *area_names(p) ].compact.map { |n| clean(n) }.uniq }
    exact = points.select { |p| names.call(p).include?(want) }
    return exact if exact.any?

    # ondaA1 (A1): a área ou o andar inteiro ("apague o térreo"), com as áreas de dentro.
    area = site.areas.to_a.find { |a| a.all_names.any? { |n| clean(n) == want } }
    return points.select { |p| area.subtree_ids.include?(p.effective_area_id) && !Kinds.setting?(site, p) } if area

    # voz-offline: tipo falado ("as luzes da sala", "janelas", "ventilador do quarto"; Assist::Kinds).
    by_kind = kind_points(site, want, points)
    return by_kind if by_kind&.any?

    words = want.split.map { |w| stem(w) }
    points.select { |p| names.call(p).any? { |n| (have = n.split.map { |w| stem(w) }) && words.all? { |w| have.include?(w) } } }
  end

  def exposed(scope) = scope.where(disabled: false, hidden: false).includes(:area, :tags, device: %i[area points]).reject { |p| p.expose.to_h["assist"] == false }

  # Pontos do tipo falado, na área dita (se houver) ou em qualquer uma; nil = a frase não começa por um tipo.
  def kind_points(site, want, points)
    kind, rest = Kinds.split(site, want)
    return unless kind

    found = points.select { |p| Kinds.match?(site, kind, p) }
    return found if rest.blank?

    area = site.areas.to_a.find { |a| a.all_names.any? { |n| clean(n) == rest } } or return []
    found.select { |p| area.subtree_ids.include?(p.effective_area_id) }
  end

  # Nome falado com a área, nos três idiomas ("luz da sala", "kitchen light", "luz de la cocina").
  def area_names(p)
    area = p.area || p.device&.area or return []
    links = [ "da", "do", "de", "na", "no", "in", "in the", "on the", "del", "de la", "en", "en la", "en el" ]
    area.all_names.product([ p.name, *p.aliases ]).flat_map { |a, n| [ "#{n} #{a}", "#{a} #{n}", *links.map { |l| "#{n} #{l} #{a}" } ] }
  end

  # Pontos de uma capacidade a partir do nome dito: o próprio ponto ou o
  # irmão do mesmo aparelho ("brilho da luz da sala" → o dimmer da lâmpada).
  # Sem nome: os da área do satélite ou, sem área, os do local.
  def targets(ctx, phrase, capabilities, command: nil)
    caps = Array(capabilities)
    list = phrase.present? ? named(ctx, phrase, caps) : nearby(ctx, exposed(ctx.site.points.where(capability: caps)))
    list = list.uniq.select { |p| p.writable && Points::Command.commands_for(p).include?(command) } if command
    list.uniq
  end

  def named(ctx, phrase, caps)
    find_points(ctx.site, phrase, area: ctx.area).flat_map { |p| caps.include?(p.capability) ? [ p ] : exposed(p.device.points.where(capability: caps)) }
  end

  # Os da área do satélite, se houver; senão todos.
  def nearby(ctx, all)
    here = ctx.area ? all.select { |p| ctx.area.subtree_ids.include?(p.effective_area_id) } : []
    here.presence || all
  end

  # O trecho da frase normalizada (sem acento) como foi dito ("pão", não
  # "pao"): mesma posição em palavras, porque a normalização é palavra a palavra.
  def original(heard, piece)
    words = heard.to_s.gsub(/[^[:alnum:] ]/, " ").split
    norm = normalize(heard).split
    return piece unless words.size == norm.size

    want = piece.to_s.split
    from = (0..(norm.size - want.size)).find { |i| norm[i, want.size] == want } or return piece
    words[from, want.size].join(" ").downcase
  end

  # Lista de tarefas pelo nome ("compras" acha "Lista de compras") ou apelido.
  LIST_PREFIX = /\A(?:lista|list|shopping list)\s+(?:de\s+|da\s+|do\s+|of\s+)?/

  def find_list(site, phrase)
    want = clean(phrase).sub(LIST_PREFIX, "").sub(/\s+(?:list|lista)\z/, "")
    lists = site.points.helpers.where(helper: HelperTypes::TodoList.key).to_a
    lists.find { |l| l.all_names.any? { |n| clean(n) == want } } ||
      lists.find { |l| l.all_names.any? { |n| clean(n).sub(LIST_PREFIX, "") == want } } ||
      (lists.first if want.in?(%w[compras shopping mercado supermercado]) && lists.one?)
  end

  def can_command?(ctx, point) = point.risk != "critical" && SiteMembership.allowed?(ctx.role, :command, risk: point.risk)
  def value_text(point) = ApplicationController.helpers.point_value_text(point)
  def list(names) = names.to_sentence

  # "50", "50%", "22,5", "cinco" → número (ou nil).
  WORDS = { "zero" => 0, "um" => 1, "uma" => 1, "one" => 1, "uno" => 1, "dois" => 2, "duas" => 2, "two" => 2, "dos" => 2, "tres" => 3, "three" => 3,
            "quatro" => 4, "four" => 4, "cuatro" => 4, "cinco" => 5, "five" => 5, "seis" => 6, "six" => 6, "sete" => 7, "seven" => 7, "siete" => 7,
            "oito" => 8, "eight" => 8, "ocho" => 8, "nove" => 9, "nine" => 9, "nueve" => 9, "dez" => 10, "ten" => 10, "diez" => 10,
            "quinze" => 15, "fifteen" => 15, "quince" => 15, "vinte" => 20, "twenty" => 20, "veinte" => 20, "trinta" => 30, "thirty" => 30,
            "treinta" => 30, "quarenta" => 40, "cinquenta" => 50, "fifty" => 50, "cincuenta" => 50, "cem" => 100, "hundred" => 100, "cien" => 100 }.freeze

  def number(text)
    s = text.to_s.strip.tr(",", ".").delete_suffix("%").strip
    s.match?(/\A\d+(?:\.\d+)?\z/) ? s.to_f : WORDS[normalize(text)]
  end

  # "5 minutos", "1 hora e 30 minutos", "meia hora", "30 seconds" → segundos.
  UNITS = { /\A(?:h|hr|hrs|horas?|hours?)\z/ => 3600, /\A(?:m|min|mins|minutos?|minutes?)\z/ => 60, /\A(?:s|seg|segs|segundos?|seconds?|secs?)\z/ => 1 }.freeze

  def seconds(text)
    s = normalize(text)
    total = 0
    total += 1800 if s.match?(/\b(?:meia hora|half an hour|media hora)\b/)
    total += 1800 if s.match?(/\bhoras? e meia\b|\bhoras? y media\b|\band a half hours?\b/)
    s.scan(/(\d+|[a-z]+)\s+([a-z]+)/).each do |n, unit|
      mult = UNITS.find { |re, _| re.match?(unit) }&.last or next
      value = n.match?(/\A\d+\z/) ? n.to_i : WORDS[n] or next
      total += value * mult
    end
    total.positive? ? total : nil
  end
end
