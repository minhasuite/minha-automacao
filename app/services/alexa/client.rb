require "net/http"

module Alexa
  # API não oficial do app Alexa (a mesma do alexa_media do HA), isolada aqui
  # para poder trocar sem mexer no resto (ESQUEMA-V1, decisão 4). Autentica
  # com os cookies de uma sessão já logada (sem login nem 2FA aqui): lista as
  # Echo e manda fala/anúncio por "sequência" (POST /api/behaviors/preview,
  # com o cabeçalho csrf = cookie csrf).
  class Client
    class Error < StandardError; end

    HOST = "alexa.amazon.com.br"
    USER_AGENT = "AmazonWebView/Amazon Alexa/2.2.443692.0/iOS/16.6/iPhone"
    LOCALE = "pt-BR"
    MAX_TEXT = 250

    # cookies: {"nome" => "valor"}.
    def initialize(cookies:, host: HOST)
      @cookies = cookies.to_h
      @host = host.presence || HOST
      raise Error, "Sem cookies da sessão da Alexa." if @cookies.empty?
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
      req["csrf"] = @cookies["csrf"].to_s
      req.body = body.to_json
      request(req)
    end

    def request(req)
      req["Cookie"] = @cookies.map { |k, v| "#{k}=#{v}" }.join("; ")
      req["User-Agent"] = USER_AGENT
      req["Accept"] = "application/json"
      req["Referer"] = "https://#{@host}/spa/index.html"
      res = Net::HTTP.start(@host, 443, use_ssl: true, open_timeout: 5, read_timeout: 15) { |h| h.request(req) }
      raise Error, "Sessão da Alexa expirada ou recusada (#{res.code}). Refaça a importação dos cookies." if %w[401 403].include?(res.code)
      raise Error, "A Alexa respondeu #{res.code}." unless res.is_a?(Net::HTTPSuccess)

      res.body.present? ? JSON.parse(res.body) : {}
    rescue JSON::ParserError
      raise Error, "Resposta ilegível da Alexa (sessão expirada?)."
    rescue SystemCallError, SocketError, Timeout::Error, IOError, OpenSSL::SSL::SSLError => e
      raise Error, "Sem conexão com a Alexa (#{e.class.name.demodulize})."
    end
  end
end
