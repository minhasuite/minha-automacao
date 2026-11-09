require "openssl"

module Tapo
  # API local de controle das câmeras Tapo (a do app, HTTPS 443 com
  # certificado próprio), no formato do pytapo/tapo_control do HA. Login com
  # "admin" + senha da nuvem (a da conta TP-Link; a conta da câmera do RTSP
  # não vale aqui):
  #
  # - **Seguro** (firmware de 2023+, `encrypt_type` 3): 1º login com cnonce →
  #   nonce + device_confirm (confere que a câmera sabe a senha: SHA-256 de
  #   cnonce + hash da senha + nonce, com o hash em SHA-256 ou MD5); 2º login
  #   com `digest_passwd` → stok e start_seq. Cada pedido vai cifrado
  #   (AES-128-CBC, chave `lsk` e IV `ivb` derivados das sementes) dentro de
  #   `securePassthrough`, com os cabeçalhos `Seq` e `Tapo_tag`.
  # - **Antigo**: login com a senha em MD5 e pedidos às claras em `/stok=…/ds`.
  #
  # Firmware de 2024+ recusa os dois (TPAP/SPAKE2+) até ligar no app Tapo
  # "Eu → Tapo Lab → Compatibilidade com terceiros"; o erro diz isso.
  class Client
    USER = "admin".freeze
    # Códigos de erro da câmera que querem dizer "a sessão venceu, entre de novo".
    EXPIRED = [ -40401, -1 ].freeze
    # Login recusado porque o firmware só aceita o protocolo novo (TPAP).
    TPAP = [ -40211, -40210 ].freeze
    BAD_LOGIN = [ -40411, -40401, -40404 ].freeze

    def initialize(host:, password:, port: 443, username: USER)
      @host = host
      @port = port.presence || 443
      @username = username
      @password = password.to_s
      @stok = nil
    end

    def base = "https://#{@host}:#{@port}"

    # Um método do multipleRequest → `result` dele.
    def call(method, params = nil)
      req = { "method" => method, "params" => params }.compact
      res = request({ "method" => "multipleRequest", "params" => { "requests" => [ req ] } })
      one = Array(res.dig("result", "responses")).first or raise Error, "Tapo: resposta sem #{method}."
      check!(one, method)
      one["result"].to_h
    end

    # Pedido fora do multipleRequest (ex.: {"method" => "do", "msg_alarm" => …}).
    def raw(body)
      res = request(body)
      check!(res, body["method"])
      res["result"].to_h
    end

    def request(body, retry_login: true)
      login! unless @stok
      res = @secure ? secure_post(body) : post("#{base}/stok=#{@stok}/ds", body.to_json)
      if EXPIRED.include?(res["error_code"].to_i) && retry_login
        @stok = nil
        return request(body, retry_login: false)
      end
      res
    end

    def login!
      @cnonce = SecureRandom.hex(8).upcase
      first = post(base, { "method" => "login", "params" => { "cnonce" => @cnonce, "encrypt_type" => "3", "username" => @username } }.to_json)
      code = first["error_code"].to_i
      raise Error, tpap_message if TPAP.include?(code)

      data = first.dig("result", "data").to_h
      if code == -40413 && Array(data["encrypt_type"]).map(&:to_s).include?("3") && data["nonce"].present?
        secure_login!(data)
      else
        legacy_login!
      end
      self
    end

    private

    def secure_login!(data)
      @nonce = data["nonce"].to_s
      @hashed = [ sha256_up(@password), md5_up(@password) ].find { |h| confirm(h) == data["device_confirm"].to_s }
      raise Integrations.auth(Error.new(I18n.t("tapo.errors.refused"))) unless @hashed

      digest = sha256_up(@hashed + @cnonce + @nonce) + @cnonce + @nonce
      res = post(base, { "method" => "login", "params" => { "cnonce" => @cnonce, "encrypt_type" => "3", "digest_passwd" => digest, "username" => @username } }.to_json)
      check_login!(res)
      key = sha256_up(@cnonce + @hashed + @nonce)
      @lsk = OpenSSL::Digest::SHA256.digest("lsk#{@cnonce}#{@nonce}#{key}").byteslice(0, 16)
      @ivb = OpenSSL::Digest::SHA256.digest("ivb#{@cnonce}#{@nonce}#{key}").byteslice(0, 16)
      @seq = res.dig("result", "start_seq").to_i
      @stok = res.dig("result", "stok").presence or raise Error, "Tapo: login sem stok."
      @secure = true
    end

    def legacy_login!
      res = post(base, { "method" => "login", "params" => { "hashed" => true, "password" => md5_up(@password), "username" => @username } }.to_json)
      check_login!(res)
      @stok = res.dig("result", "stok").presence or raise Error, "Tapo: login sem stok."
      @secure = false
    end

    def check_login!(res)
      code = res["error_code"].to_i
      return if code.zero?
      raise Error, tpap_message if TPAP.include?(code)
      raise Integrations.auth(Error.new(I18n.t("tapo.errors.refused"))) if BAD_LOGIN.include?(code)

      raise Error, "Tapo: login recusado (#{code})."
    end

    def confirm(hashed) = sha256_up(@cnonce + hashed + @nonce) + @nonce + @cnonce

    def secure_post(body)
      payload = { "method" => "securePassthrough", "params" => { "request" => Base64.strict_encode64(cipher(:encrypt, body.to_json)) } }.to_json
      tag = sha256_up(sha256_up(@hashed + @cnonce) + payload + @seq.to_s)
      res = post("#{base}/stok=#{@stok}/ds", payload, "Seq" => @seq.to_s, "Tapo_tag" => tag)
      @seq += 1
      inner = res.dig("result", "response") or return res
      JSON.parse(cipher(:decrypt, Base64.decode64(inner)))
    rescue OpenSSL::Cipher::CipherError, JSON::ParserError
      @stok = nil
      raise Error, "Tapo: resposta cifrada ilegível."
    end

    def cipher(mode, data)
      c = OpenSSL::Cipher.new("aes-128-cbc").public_send(mode)
      c.key = @lsk
      c.iv = @ivb
      c.update(data) + c.final
    end

    def post(url, json, headers = {})
      LanHttp.call(:post, url, body: json, headers: { "Content-Type" => "application/json; charset=UTF-8", "Accept" => "application/json" }.merge(headers),
                               insecure: true) # certificado próprio da câmera
    end

    def check!(res, method)
      code = res["error_code"].to_i
      raise Error, "Tapo: #{method} recusado (#{code})." unless code.zero?
    end

    def tpap_message = I18n.t("tapo.errors.tpap")
    def sha256_up(s) = OpenSSL::Digest::SHA256.hexdigest(s).upcase
    def md5_up(s) = OpenSSL::Digest::MD5.hexdigest(s).upcase
  end
end
