require "net/http"

module Alexa
  # API não oficial do app Alexa (a mesma do alexa_media do HA), isolada aqui
  # para poder trocar sem mexer no resto (ESQUEMA-V1, decisão 4). Autentica
  # com os cookies da sessão (login próprio em Alexa::Auth, Lote 3, ou
  # cookies colados): lista as Echo, manda fala/anúncio por "sequência"
  # (POST /api/behaviors/preview, com o cabeçalho csrf = cookie csrf) e roda
  # rotinas da conta.
  class Client
    class Error < StandardError; end

    HOST = "alexa.amazon.com.br"
    USER_AGENT = "AmazonWebView/Amazon Alexa/2.2.443692.0/iOS/16.6/iPhone"
    LOCALE = "pt-BR"
    MAX_TEXT = 250

    # cookies: {"nome" => "valor"}. `renew`: bloco que devolve cookies novos
    # (Alexa::Auth.refresh!); com ele, uma recusa (401/403) renova e repete uma vez.
    def initialize(cookies:, host: HOST, renew: nil)
      @cookies = cookies.to_h
      @host = host.presence || HOST
      @renew = renew
      raise Integrations.auth(Error.new("Sem cookies da sessão da Alexa.")) if @cookies.empty?
    end

    # [{"serialNumber", "deviceType", "accountName", "deviceFamily", "online", "deviceOwnerCustomerId", ...}]
    def devices
      Array(get("/api/devices-v2/device?cached=true")["devices"])
    end

    # Fala o texto na Echo (TTS, sem o som de anúncio).
    def speak(device, text)
      sequence(node("Alexa.Speak", "deviceType" => device[:type], "deviceSerialNumber" => device[:serial],
                                   "locale" => LOCALE, "customerId" => device[:customer_id], "textToSpeak" => text(text)))
    end

    # Anúncio (som de aviso + fala) numa ou mais Echo da mesma conta.
    def announce(devices, text, title: "Aviso")
      devices = Array(devices)
      customer = devices.first&.dig(:customer_id) or raise Error, "Nenhuma Echo para anunciar."
      sequence(node("AlexaAnnouncement",
                    "expireAfter" => "PT5S", "customerId" => customer,
                    "content" => [ { "locale" => LOCALE, "display" => { "title" => title.to_s.truncate(60), "body" => text(text) },
                                     "speak" => { "type" => "text", "value" => text(text) } } ],
                    "target" => { "customerId" => customer,
                                  "devices" => devices.map { |d| { "deviceSerialNumber" => d[:serial], "deviceTypeId" => d[:type] } } }))
    end

    # G12 (Lote 8), mesmas operações do alexa_media: som da biblioteca da
    # Alexa (`amzn_sfx_doorbell_chime_01`), busca de música no provedor e volume.
    SOUND = /\A[a-z0-9_.:-]{3,120}\z/i
    PROVIDERS = %w[AMAZON_MUSIC SPOTIFY APPLE_MUSIC DEEZER TUNEIN I_HEART_RADIO SIRIUSXM].freeze

    def sound(device, sound_id)
      raise Error, "Som inválido (use o id do som da Alexa, ex.: amzn_sfx_doorbell_chime_01)." unless sound_id.to_s.match?(SOUND)

      sequence(node("Alexa.Sound", target(device).merge("soundStringId" => sound_id.to_s)))
    end

    # Texto "provedor: busca" (AMAZON_MUSIC padrão).
    def play(device, phrase)
      provider, search = phrase.to_s.split(":", 2).map(&:strip)
      provider, search = "AMAZON_MUSIC", phrase unless search && PROVIDERS.include?(provider.upcase)
      sequence(node("Alexa.Music.PlaySearchPhrase", target(device).merge("searchPhrase" => text(search), "sanitizedSearchPhrase" => text(search).downcase,
                                                                          "musicProviderId" => provider.upcase)))
    end

    def volume(device, level)
      sequence(node("Alexa.DeviceControls.Volume", target(device).merge("value" => level.to_i.clamp(0, 100))))
    end

    # Rotinas da conta: [{"automationId", "name", "triggers", "sequence", ...}].
    def routines = Array(get("/api/behaviors/v2/automations?limit=2000"))

    # Roda a rotina pelo nome (ou pela frase que a dispara) como se fosse dita nesta Echo.
    def run_routine(device, name)
      wanted = name.to_s.squish.downcase
      routine = routines.find do |r|
        r["name"].to_s.squish.downcase == wanted || Array(r["triggers"]).any? { |t| t.dig("payload", "utterance").to_s.squish.downcase == wanted }
      end
      raise Error, "Rotina \"#{name.to_s.squish}\" não encontrada na conta." unless routine

      seq = routine["sequence"].to_json.gsub("ALEXA_CURRENT_DEVICE_TYPE", device[:type].to_s).gsub("ALEXA_CURRENT_DSN", device[:serial].to_s)
                                       .gsub("ALEXA_CUSTOMER_ID", device[:customer_id].to_s).gsub("ALEXA_CURRENT_LOCALE", LOCALE)
      post("/api/behaviors/preview", { "behaviorId" => routine["automationId"], "sequenceJson" => seq, "status" => "ENABLED" })
    end

    # Lote 9: o que foi dito às Echo desde `since` (histórico de voz da conta,
    # o mesmo que o alexa_media lê para o `last_called`), mais novo primeiro:
    # [{serial:, at:, text:}]. Só leitura; fica no site da loja (`www.`), com o
    # token anti-CSRF da página de atividade.
    VOICE_TEXT = %w[CUSTOMER_TRANSCRIPT ASR_REPLACEMENT_TEXT].freeze
    VOICE_SKIP = %w[WAKE_WORD_ONLY DEVICE_ARBITRATION].freeze

    def voice_history(since:, to: Time.current)
      www = @host.sub(/\Aalexa\./, "www.")
      page = request(Net::HTTP::Get.new("/alexa-privacy/apd/activity?disableGlobalNav=true&ref=activityHistory").tap { |r| r["Accept"] = "text/html" }, www, json: false)
      token = page[/<meta name="csrf-token" content="([^"]+)"/, 1] or raise Integrations.auth(Error.new("Histórico de voz da Alexa sem acesso (entre de novo pela conta Amazon)."))
      req = Net::HTTP::Post.new("/alexa-privacy/apd/rvh/customer-history-records-v2/?startTime=#{(since.to_f * 1000).to_i}&endTime=#{(to.to_f * 1000).to_i}&disableGlobalNav=false")
      req["anti-csrftoken-a2z"] = token
      req["Content-Type"] = "application/json; charset=UTF-8"
      req.body = { "previousRequestToken" => nil }.to_json
      Array(request(req, www)["customerHistoryRecords"]).filter_map { |r| voice_record(r) }.sort_by { |r| -r[:at].to_f }
    end

    # Corpo do POST da sequência (público para os specs conferirem a montagem).
    def self.sequence_body(start_node)
      { "behaviorId" => "PREVIEW", "status" => "ENABLED",
        "sequenceJson" => { "@type" => "com.amazon.alexa.behaviors.model.Sequence", "startNode" => start_node }.to_json }
    end

    private

    # recordKey = "cliente#tipo#…#número de série" (posição 3, como no alexapy).
    def voice_record(r)
      serial = r["recordKey"].to_s.split("#")[3]
      return if serial.blank? || VOICE_SKIP.include?(r["utteranceType"])

      text = Array(r["voiceHistoryRecordItems"]).find { |i| VOICE_TEXT.include?(i["recordItemType"]) }&.dig("transcriptText")
      { serial: serial, at: Time.zone.at(r["timestamp"].to_i / 1000.0), text: text.to_s }
    end

    def target(device)
      { "deviceType" => device[:type], "deviceSerialNumber" => device[:serial], "locale" => LOCALE, "customerId" => device[:customer_id] }
    end

    def node(type, payload)
      { "@type" => "com.amazon.alexa.behaviors.model.OpaquePayloadOperationNode", "type" => type, "operationPayload" => payload }
    end

    def text(value)
      s = value.to_s.squish
      raise Error, "Texto vazio." if s.empty?

      s.truncate(MAX_TEXT)
    end

    def sequence(start_node) = post("/api/behaviors/preview", self.class.sequence_body(start_node))

    def get(path) = request(Net::HTTP::Get.new(path))

    def post(path, body)
      req = Net::HTTP::Post.new(path)
      req["Content-Type"] = "application/json; charset=UTF-8"
      req.body = body.to_json
      request(req)
    end

    # `host`: o site da Alexa (padrão) ou o da loja (`www.`, histórico de voz); `json` falso = texto da página.
    def request(req, host = @host, json: true)
      req["Cookie"] = @cookies.map { |k, v| "#{k}=#{v}" }.join("; ")
      req["csrf"] = @cookies["csrf"].to_s if req.request_body_permitted?
      req["User-Agent"] = USER_AGENT
      req["Accept"] ||= "application/json"
      req["Referer"] = "https://#{@host}/spa/index.html"
      res = Net::HTTP.start(host, 443, use_ssl: true, open_timeout: 5, read_timeout: 15) { |h| h.request(req) }
      if %w[401 403].include?(res.code)
        return renew_and_retry(req, host, json) if @renew && !@renewed

        raise Integrations.auth(Error.new("Sessão da Alexa expirada ou recusada (#{res.code}). Entre de novo pela conta Amazon (Reconfigurar)."))
      end
      raise Error, "A Alexa respondeu #{res.code}." unless res.is_a?(Net::HTTPSuccess)
      return res.body.to_s unless json

      res.body.present? ? JSON.parse(res.body) : {}
    rescue JSON::ParserError
      raise Error, "Resposta ilegível da Alexa (sessão expirada?)."
    rescue SystemCallError, SocketError, Timeout::Error, IOError, OpenSSL::SSL::SSLError => e
      raise Error, "Sem conexão com a Alexa (#{e.class.name.demodulize})."
    end

    def renew_and_retry(req, host, json)
      @renewed = true
      @cookies = @renew.call.to_h
      request(req, host, json: json)
    end
  end
end
