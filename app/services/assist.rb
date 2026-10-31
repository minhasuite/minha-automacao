# Voz local (Pacote 3; o Assist do HA): frase (digitada ou transcrita pelo
# STT da instalação) → intenção local resolvida pelos nomes e apelidos dos
# pontos, áreas e cenas, sem IA. Não reconheceu: cai no "Perguntar à casa"
# (Ai::Ask, só leitura). A resposta é texto e, se pedir, fala (TTS).
#
# Intenção nova = classe em Assist::Intents com `pattern` (regex sobre a
# frase normalizada) e `handle(ctx, match)` → Reply ou nil (não é comigo) +
# nome em `INTENTS`. Comando por voz respeita o papel x risco de quem fala,
# a sombra do local e nunca comanda ponto crítico (portão, fechadura).
module Assist
  INTENTS = %w[TurnOnOff ReadState ActivateScene].freeze
  MAX_TEXT = 300

  Reply = Data.define(:text, :intent, :points) do
    def initialize(text:, intent:, points: []) = super
  end

  # Quem pergunta e onde (o papel decide o que a voz pode comandar).
  Ctx = Data.define(:site, :user, :role)

  module_function

  def intents = INTENTS.map { |n| Intents.const_get(n) }

  # → { text:, intent:, heard:, points:, audio_url? }
  def call(site:, user:, text:, speak: false)
    heard = text.to_s.squish.first(MAX_TEXT)
    raise ArgumentError, "Fale ou escreva o que quer." if heard.empty?

    ctx = Ctx.new(site: site, user: user, role: site.role_for(user))
    norm = normalize(heard)
    reply = intents.lazy.filter_map { |i| (m = i.pattern.match(norm)) && i.handle(ctx, m) }.first || ask(ctx, heard)
    out = { "heard" => heard, "text" => reply.text, "intent" => reply.intent, "points" => reply.points.map(&:id) }
    out["audio_url"] = speech(site, reply.text) if speak
    out
  end

  # Áudio (bytes do microfone) → texto pelo STT da instalação.
  def transcribe(site:, audio:, media_type:)
    res = Ai::Audio.transcribe(tenant: site.tenant, site: site, audio: audio, media_type: media_type, language: "pt", source: "voz")
    res.data.to_s.dup.force_encoding(Encoding::UTF_8).scrub.squish
  end

  def speech(site, text)
    res = Ai::Audio.speak(tenant: site.tenant, site: site, text: text, source: "voz")
    Ai::Audio.store(res.data[:data], res.data[:media_type], "assistente-#{Time.current.to_i}").last
  rescue Ai::Client::Error => e
    Rails.logger.info("[assist] sem fala: #{e.message}")
    nil
  end

  def ask(ctx, heard)
    Reply.new(text: Ai::Ask.call(site: ctx.site, question: heard), intent: "ask")
  rescue Ai::Client::Error => e
    Reply.new(text: "Não entendi e não consegui perguntar à IA (#{e.message.truncate(80)}). Tente \"ligar a luz da sala\".", intent: "unknown")
  end

  # Sem acento, minúsculas, sem pontuação e sem artigo no começo.
  def normalize(text)
    I18n.transliterate(text.to_s).downcase.gsub(/[^a-z0-9 ]/, " ").squish
  end

  STOP = /\A(?:(?:o|a|os|as|do|da|dos|das|de|no|na|nos|nas|em|um|uma|todas?|todos?)\s+)+/

  def clean(phrase) = normalize(phrase).sub(STOP, "").sub(/\s+(?:por favor|agora|pra mim)\z/, "").strip

  # Pontos que a frase nomeia: o nome, o apelido falado (Alexa), "nome da
  # área" ou a área inteira. Exato ganha de "contém".
  def find_points(site, phrase, scope: nil)
    want = clean(phrase)
    return [] if want.empty?

    points = (scope || site.points).where(disabled: false, hidden: false).includes(:area, device: :area).to_a
    names = ->(p) { [ p.name, p.alexa_name, p.display_names.compact.join(" "), *area_names(p) ].compact.map { |n| clean(n) }.uniq }
    exact = points.select { |p| names.call(p).include?(want) }
    return exact if exact.any?

    area = site.areas.to_a.find { |a| clean(a.name) == want }
    return points.select { |p| p.effective_area_id == area.id } if area

    words = want.split
    points.select { |p| names.call(p).any? { |n| words.all? { |w| n.split.include?(w) } } }
  end

  def area_names(p)
    area = p.area || p.device&.area or return []
    [ "#{p.name} da #{area.name}", "#{p.name} do #{area.name}", "#{p.name} #{area.name}" ]
  end

  def can_command?(ctx, point) = point.risk != "critical" && SiteMembership.allowed?(ctx.role, :command, risk: point.risk)
  def value_text(point) = ApplicationController.helpers.point_value_text(point)
  def list(names) = names.size > 1 ? "#{names[0..-2].join(', ')} e #{names.last}" : names.first.to_s

  module Intents
    # "ligar a luz da sala", "desligue a sala", "apagar a varanda".
    class TurnOnOff
      ON = %w[ligar liga ligue acender acende acenda].freeze
      OFF = %w[desligar desliga desligue apagar apaga apague].freeze

      def self.pattern = /\A(#{(ON + OFF).join('|')})\s+(.+)\z/

      def self.handle(ctx, m)
        command = ON.include?(m[1]) ? "on" : "off"
        points = Assist.find_points(ctx.site, m[2]).select { |p| p.writable && Points::Command.commands_for(p).include?(command) }
        return if points.empty?

        allowed, denied = points.partition { |p| Assist.can_command?(ctx, p) }
        return Reply.new(text: "Por voz não posso comandar #{Assist.list(denied.map(&:name))}.", intent: "turn_#{command}") if allowed.empty?

        failed = []
        Shadow.for_site(ctx.site) do
          allowed.each do |p|
            c = Points::Command.call(p, command, nil, source: "voice", user: ctx.user)
            failed << p.name if c.error
          rescue Points::Command::Error => e
            failed << "#{p.name} (#{e.message})"
          end
        end
        ok = allowed.map(&:name) - failed.map { |f| f.sub(/ \(.*/, "") }
        text = [ ("#{command == 'on' ? 'Liguei' : 'Desliguei'} #{Assist.list(ok)}." if ok.any?), ("Não consegui: #{Assist.list(failed)}." if failed.any?),
                 ("Sem permissão por voz: #{Assist.list(denied.map(&:name))}." if denied.any?) ].compact.join(" ")
        Reply.new(text: text, intent: "turn_#{command}", points: allowed)
      end
    end

    # "qual a temperatura da sala", "como está a porta da frente", "quanto está o consumo".
    class ReadState
      def self.pattern = /\A(?:qual|quanto|como|quantos|quantas)\s+(?:e|esta|ta|estao|marca)?\s*(.+?)\s*\z/

      def self.handle(ctx, m)
        points = Assist.find_points(ctx.site, m[1]).first(5)
        return if points.empty?

        text = points.map { |p| "#{p.display_names.compact.join(' ')}: #{p.quality == 'good' ? Assist.value_text(p) : 'sem sinal'}" }.join(". ")
        Reply.new(text: "#{text}.", intent: "read_state", points: points)
      end
    end

    # "ativar a cena cinema", "acionar cena boa noite" (cena do local).
    class ActivateScene
      def self.pattern = /\A(?:ativar|ative|ativa|acionar|acione|aciona|executar|execute)\s+(?:(?:a|o)\s+)?(?:cena\s+)?(.+)\z/

      def self.handle(ctx, m)
        want = Assist.clean(m[1])
        scene = ctx.site.scenes.to_a.find { |s| Assist.clean(s.name) == want } or return
        return Reply.new(text: "Por voz não posso acionar a cena #{scene.name}.", intent: "scene") unless scene.risk != "critical" && SiteMembership.allowed?(ctx.role, :command, risk: scene.risk)

        _commands, failures = scene.activate!(source: "voice", user: ctx.user)
        Reply.new(text: failures.any? ? "Cena #{scene.name} com falhas: #{failures.to_sentence}." : "Cena #{scene.name} acionada.", intent: "scene")
      end
    end
  end
end
