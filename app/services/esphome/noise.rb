require "openssl"

module Esphome
  # Noise_NNpsk0_25519_ChaChaPoly_SHA256, como a API nativa do ESPHome com
  # `encryption: key` (prólogo "NoiseAPIInit\0\0", psk = a chave base64 de 32
  # bytes). Só o necessário: duas mensagens de handshake e as cifras de ida
  # e volta. Serve aos dois lados (o responder é usado pelo servidor falso dos
  # specs).
  class Noise
    NAME = "Noise_NNpsk0_25519_ChaChaPoly_SHA256".b
    PROLOGUE = "NoiseAPIInit\x00\x00".b
    DH_LEN = 32
    TAG_LEN = 16

    # Estado da cifra: chave + contador (nonce = 4 zeros + n em 64 bits LE).
    class CipherState
      def initialize(key)
        @key = key
        @n = 0
      end

      def encrypt(ad, plaintext)
        c = cipher(:encrypt, ad)
        update(c, plaintext) + c.final + c.auth_tag
      end

      def decrypt(ad, data)
        raise Error, "Mensagem cifrada curta demais." if data.bytesize < TAG_LEN

        c = cipher(:decrypt, ad)
        c.auth_tag = data.byteslice(-TAG_LEN, TAG_LEN)
        update(c, data.byteslice(0, data.bytesize - TAG_LEN)) + c.final
      rescue OpenSSL::Cipher::CipherError
        raise Error, "Chave de criptografia recusada (mensagem não confere)."
      end

      private

      # O OpenSSL recusa `update("")` (o handshake cifra carga vazia).
      def update(c, data) = data.empty? ? "".b : c.update(data)

      def cipher(mode, ad)
        c = OpenSSL::Cipher.new("chacha20-poly1305").public_send(mode)
        c.key = @key
        c.iv = "\x00\x00\x00\x00".b + [ @n ].pack("Q<")
        @n += 1
        c.auth_data = ad
        c
      end
    end

    attr_reader :sender, :receiver

    def self.psk(key_b64)
      raw = Base64.strict_decode64(key_b64.to_s.strip)
      raise Error, "A chave de criptografia deve ter 32 bytes em base64." unless raw.bytesize == 32

      raw
    rescue ArgumentError
      raise Error, "A chave de criptografia não é base64 válido."
    end

    def initialize(psk, initiator: true)
      @psk = psk
      @initiator = initiator
      @h = NAME.bytesize <= 32 ? NAME.ljust(32, "\x00") : sha(NAME)
      @ck = @h
      @cipher = nil
      mix_hash(PROLOGUE)
    end

    # Iniciador → "psk, e".
    def write_first
      mix_key_and_hash(@psk)
      @e = OpenSSL::PKey.generate_key("X25519")
      pub = @e.raw_public_key
      mix_hash(pub)
      mix_key(pub)
      pub + encrypt_and_hash("".b)
    end

    def read_first(msg)
      mix_key_and_hash(@psk)
      @re = msg.byteslice(0, DH_LEN)
      mix_hash(@re)
      mix_key(@re)
      decrypt_and_hash(msg.byteslice(DH_LEN..))
    end

    # Responder → "e, ee".
    def write_second
      @e = OpenSSL::PKey.generate_key("X25519")
      pub = @e.raw_public_key
      mix_hash(pub)
      mix_key(pub)
      mix_key(dh(@re))
      out = pub + encrypt_and_hash("".b)
      split!
      out
    end

    def read_second(msg)
      raise Error, "Resposta do handshake curta demais." if msg.bytesize < DH_LEN

      re = msg.byteslice(0, DH_LEN)
      mix_hash(re)
      mix_key(re)
      mix_key(dh(re))
      decrypt_and_hash(msg.byteslice(DH_LEN..))
      split!
    end

    private

    def dh(pub) = @e.derive(OpenSSL::PKey.new_raw_public_key("X25519", pub))
    def sha(data) = OpenSSL::Digest::SHA256.digest(data)
    def hmac(key, data) = OpenSSL::HMAC.digest("SHA256", key, data)

    def hkdf(ikm, n)
      temp = hmac(@ck, ikm)
      out = [ hmac(temp, "\x01".b) ]
      out << hmac(temp, out.last + [ out.size + 1 ].pack("C")) while out.size < n
      out
    end

    def mix_hash(data) = @h = sha(@h + data)

    def mix_key(ikm)
      @ck, key = hkdf(ikm, 2)
      @cipher = CipherState.new(key)
    end

    def mix_key_and_hash(ikm)
      @ck, temp_h, key = hkdf(ikm, 3)
      mix_hash(temp_h)
      @cipher = CipherState.new(key)
    end

    def encrypt_and_hash(plaintext)
      ct = @cipher ? @cipher.encrypt(@h, plaintext) : plaintext
      mix_hash(ct)
      ct
    end

    def decrypt_and_hash(ct)
      pt = @cipher ? @cipher.decrypt(@h, ct) : ct
      mix_hash(ct)
      pt
    end

    def split!
      k1, k2 = hkdf("".b, 2)
      @sender, @receiver = @initiator ? [ CipherState.new(k1), CipherState.new(k2) ] : [ CipherState.new(k2), CipherState.new(k1) ]
    end
  end
end
