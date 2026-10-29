require "openssl"
require "base64"
require "json"
require "zlib"

module Tuya
  # Protocolo Tuya local (LAN, TCP 6668), versões 3.1, 3.3, 3.4 e 3.5, sem
  # rede: monta e desmonta quadros. Ruby puro (sem Rails) de propósito.
  #
  # 55AA (3.1–3.4): prefixo, seq, cmd, tamanho, payload, CRC32 (HMAC-SHA256
  # na 3.4), sufixo. 3.1 cifra só o CONTROL (AES-ECB + base64 + md5); 3.3
  # cifra tudo com a local_key; 3.4 negocia uma chave de sessão.
  # 6699 (3.5): AES-GCM com IV de 12 bytes e tag de 16, chave de sessão.
  class Protocol
    PREFIX_55AA = 0x000055AA
    SUFFIX_55AA = 0x0000AA55
    PREFIX_6699 = 0x00006699
    SUFFIX_6699 = 0x00009966

    SESS_KEY_NEG_START = 3
    SESS_KEY_NEG_RESP = 4
    SESS_KEY_NEG_FINISH = 5
    CONTROL = 7
    STATUS = 8
    HEART_BEAT = 9
    DP_QUERY = 10
    CONTROL_NEW = 13
    DP_QUERY_NEW = 16
    UPDATEDPS = 18
    # Comandos que vão sem o cabeçalho "3.x" + 12 bytes.
    NO_HEADER = [ DP_QUERY, DP_QUERY_NEW, UPDATEDPS, HEART_BEAT, SESS_KEY_NEG_START, SESS_KEY_NEG_RESP, SESS_KEY_NEG_FINISH ].freeze
    VERSIONS = %w[3.1 3.3 3.4 3.5].freeze

    class Error < StandardError; end

    Message = Struct.new(:seq, :cmd, :retcode, :payload, keyword_init: true) do
      def json = (JSON.parse(payload.dup.force_encoding("UTF-8")) if payload.start_with?("{"))
      # dps vem em {"dps": …} (3.1/3.3) ou {"data": {"dps": …}} (3.4/3.5).
      def dps
        j = json
        j && (j["dps"] || j.dig("data", "dps"))
      rescue JSON::ParserError
        nil
      end
    end

    attr_reader :version
    attr_accessor :key

    def initialize(version, local_key)
      raise Error, "versão #{version} não suportada" unless VERSIONS.include?(version.to_s)
      raise Error, "local_key precisa ter 16 caracteres" unless local_key.to_s.bytesize == 16

      @version = version.to_s
      @local_key = local_key.to_s.b
      @key = @local_key
    end

    def session? = version >= "3.4"

    # Quadro do cliente para o aparelho (payload: texto ou bytes, sem cifra).
    def pack(seq, cmd, payload)
      payload = payload.to_s.b
      version == "3.5" ? pack_6699(seq, cmd, payload) : pack_55aa(seq, cmd, encode(cmd, payload))
    end

    # Tira o primeiro quadro completo do buffer: [Message, resto] ou nil se
    # ainda não chegou tudo. Lixo antes do prefixo é descartado.
    def unpack(buffer)
      buffer = buffer.b
      start = buffer.index([ version == "3.5" ? PREFIX_6699 : PREFIX_55AA ].pack("N"))
      return nil unless start

      buffer = buffer.byteslice(start..)
      version == "3.5" ? unpack_6699(buffer) : unpack_55aa(buffer)
    end

    # Negociação de sessão (3.4/3.5): passo 1 manda o nonce local; com a
    # resposta do aparelho, o passo 2 devolve o payload do FINISH e troca a
    # chave para a de sessão.
    def session_finish(local_nonce, response)
      remote_nonce = response.byteslice(0, 16)
      unless OpenSSL.secure_compare(response.byteslice(16, 32).to_s, hmac(@local_key, local_nonce))
        raise Error, "aparelho recusou a negociação (local_key errada?)"
      end

      finish = hmac(@local_key, remote_nonce)
      xor = local_nonce.bytes.zip(remote_nonce.bytes).map { |a, b| a ^ b }.pack("C*")
      @key = version == "3.5" ? gcm_encrypt(@local_key, local_nonce.byteslice(0, 12), xor, "").first : ecb_encrypt(@local_key, xor, pad: false)
      finish
    end

    def reset_key! = (@key = @local_key)

    def header_bytes = "#{version}#{"\0" * 12}".b

    private

    def encode(cmd, payload)
      case version
      when "3.1"
        return payload unless cmd == CONTROL

        b64 = Base64.strict_encode64(ecb_encrypt(@key, payload))
        "3.1".b + OpenSSL::Digest::MD5.hexdigest("data=#{b64}||lpv=3.1||#{@key}")[8, 16] + b64
      when "3.3"
        enc = ecb_encrypt(@key, payload)
        NO_HEADER.include?(cmd) ? enc : header_bytes + enc
      else
        ecb_encrypt(@key, NO_HEADER.include?(cmd) ? payload : header_bytes + payload)
      end
    end

    def pack_55aa(seq, cmd, payload)
      header = [ PREFIX_55AA, seq, cmd, payload.bytesize + (version == "3.4" ? 32 : 4) + 4 ].pack("N4")
      body = header + payload
      check = version == "3.4" ? hmac(@key, body) : [ Zlib.crc32(body) ].pack("N")
      body + check + [ SUFFIX_55AA ].pack("N")
    end

    def pack_6699(seq, cmd, payload)
      plain = NO_HEADER.include?(cmd) ? payload : header_bytes + payload
      iv = OpenSSL::Random.random_bytes(12)
      header = [ PREFIX_6699, 0, seq, cmd, 12 + plain.bytesize + 16 ].pack("NnN3")
      ct, tag = gcm_encrypt(@key, iv, plain, header.byteslice(4..))
      header + iv + ct + tag + [ SUFFIX_6699 ].pack("N")
    end

    def unpack_55aa(buffer)
      return nil if buffer.bytesize < 16

      _, seq, cmd, len = buffer.unpack("N4")
      return nil if buffer.bytesize < 16 + len

      check_size = version == "3.4" ? 32 : 4
      raise Error, "quadro com tamanho inválido" if len < check_size + 4

      body = buffer.byteslice(0, 16 + len - check_size - 4)
      check = buffer.byteslice(16 + len - check_size - 4, check_size)
      expected = version == "3.4" ? hmac(@key, body) : [ Zlib.crc32(body) ].pack("N")
      raise Error, "quadro corrompido (#{version == '3.4' ? 'HMAC' : 'CRC'})" unless check == expected

      retcode, payload = split_retcode(body.byteslice(16..))
      [ Message.new(seq: seq, cmd: cmd, retcode: retcode, payload: decode(payload)), buffer.byteslice(16 + len..) ]
    end

    def unpack_6699(buffer)
      return nil if buffer.bytesize < 18

      _, _, seq, cmd, len = buffer.unpack("NnN3")
      return nil if buffer.bytesize < 18 + len + 4
      raise Error, "quadro com tamanho inválido" if len < 28

      body = buffer.byteslice(18, len)
      plain = gcm_decrypt(@key, body.byteslice(0, 12), body.byteslice(12, len - 28), body.byteslice(len - 16, 16), buffer.byteslice(4, 14))
      retcode, payload = split_retcode(plain)
      [ Message.new(seq: seq, cmd: cmd, retcode: retcode, payload: strip_header(payload)), buffer.byteslice(18 + len + 4..) ]
    end

    # Resposta do aparelho começa com um código de retorno de 4 bytes (0 = ok);
    # payload cifrado ou JSON não começa com três zeros.
    def split_retcode(data)
      return [ nil, data ] if data.bytesize < 4 || data.byteslice(0, 3) != "\0\0\0".b

      [ data.unpack1("N"), data.byteslice(4..) ]
    end

    def decode(payload)
      return payload if payload.empty?

      case version
      when "3.1"
        return payload unless payload.start_with?("3.1")

        ecb_decrypt(@key, Base64.decode64(payload.byteslice(19..)))
      when "3.3"
        payload = payload.byteslice(15..) if payload.start_with?("3.3")
        payload.start_with?("{") || payload.empty? ? payload : ecb_decrypt(@key, payload)
      else
        strip_header(ecb_decrypt(@key, payload))
      end
    rescue OpenSSL::Cipher::CipherError
      payload # texto puro de erro ("json obj data unvalid")
    end

    def strip_header(payload)
      payload.start_with?(version) && payload.bytesize >= 15 ? payload.byteslice(15..) : payload
    end

    def hmac(key, data) = OpenSSL::HMAC.digest("SHA256", key, data)

    def ecb_encrypt(key, data, pad: true)
      c = OpenSSL::Cipher.new("aes-128-ecb").encrypt
      c.key = key
      c.padding = 0 unless pad
      c.update(data) + c.final
    end

    def ecb_decrypt(key, data)
      c = OpenSSL::Cipher.new("aes-128-ecb").decrypt
      c.key = key
      c.update(data) + c.final
    end

    def gcm_encrypt(key, iv, data, aad)
      c = OpenSSL::Cipher.new("aes-128-gcm").encrypt
      c.key = key
      c.iv = iv
      c.auth_data = aad unless aad.empty?
      [ c.update(data) + c.final, c.auth_tag ]
    end

    def gcm_decrypt(key, iv, data, tag, aad)
      c = OpenSSL::Cipher.new("aes-128-gcm").decrypt
      c.key = key
      c.iv = iv
      c.auth_tag = tag
      c.auth_data = aad
      c.update(data) + c.final
    rescue OpenSSL::Cipher::CipherError
      raise Error, "quadro corrompido (GCM)"
    end
  end
end
