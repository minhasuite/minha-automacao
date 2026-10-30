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

    # Corpo do POST da sequência (público para os specs conferirem a montagem).
    def self.sequence_body(start_node)
      { "behaviorId" => "PREVIEW", "status" => "ENABLED",
        "sequenceJson" => { "@type" => "com.amazon.alexa.behaviors.model.Sequence", "startNode" => start_node }.to_json }
    end

    private

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

    def request(req)
      req["Cookie"] = @cookies.map { |k, v| "#{k}=#{v}" }.join("; ")
      req["csrf"] = @cookies["csrf"].to_s if req.request_body_permitted?
      req["User-Agent"] = USER_AGENT
      req["Accept"] = "application/json"
      req["Referer"] = "https://#{@host}/spa/index.html"
      res = Net::HTTP.start(@host, 443, use_ssl: true, open_timeout: 5, read_timeout: 15) { |h| h.request(req) }
      if %w[401 403].include?(res.code)
        return renew_and_retry(req) if @renew && !@renewed

        raise Integrations.auth(Error.new("Sessão da Alexa expirada ou recusada (#{res.code}). Entre de novo pela conta Amazon (Reconfigurar)."))
      end
      raise Error, "A Alexa respondeu #{res.code}." unless res.is_a?(Net::HTTPSuccess)

      res.body.present? ? JSON.parse(res.body) : {}
    rescue JSON::ParserError
      raise Error, "Resposta ilegível da Alexa (sessão expirada?)."
    rescue SystemCallError, SocketError, Timeout::Error, IOError, OpenSSL::SSL::SSLError => e
      raise Error, "Sem conexão com a Alexa (#{e.class.name.demodulize})."
    end

    def renew_and_retry(req)
      @renewed = true
      @cookies = @renew.call.to_h
      request(req)
    end
  end
end
