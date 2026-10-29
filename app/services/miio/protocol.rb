require "openssl"

module Miio
  # Quadros do protocolo miIO (UDP 54321), sem rede. Cabeçalho de 32 bytes:
  # magic 0x2131, tamanho total, 4 bytes zerados, did, carimbo (stamp) e o
  # MD5 de (cabeçalho + token + dados). Os dados são o JSON do comando cifrado
  # em AES-128-CBC com chave = MD5(token) e iv = MD5(chave + token). O "hello"
  # (32 bytes, 0xff depois do tamanho) devolve did e carimbo do aparelho.
  module Protocol
    class Error < StandardError; end

    MAGIC = 0x2131
    HEADER = 32
    HELLO = ([ MAGIC, HEADER ].pack("nn") + ("\xff".b * 28)).freeze

    module_function

    # token: os 16 bytes (não o hex).
    def key_iv(token)
      key = Digest::MD5.digest(token)
      [ key, Digest::MD5.digest(key + token) ]
    end

    def encrypt(token, plain)
      cipher(:encrypt, token, plain)
    end

    def decrypt(token, data)
      cipher(:decrypt, token, data)
    end

    def encode(token, did:, stamp:, payload:)
      data = encrypt(token, payload)
      header = [ MAGIC, HEADER + data.bytesize, 0, did, stamp ].pack("nnNNN")
      header + Digest::MD5.digest(header + token + data) + data
    end

    # {did:, stamp:, payload:} (payload nil = resposta do hello).
    def decode(token, packet)
      packet = packet.b
      raise Error, "quadro curto" if packet.bytesize < HEADER

      magic, size, _zero, did, stamp = packet.unpack("nnNNN")
      raise Error, "quadro inválido" unless magic == MAGIC && size == packet.bytesize

      data = packet.byteslice(HEADER..)
      return { did: did, stamp: stamp, payload: nil } if data.empty?

      raise Error, "checksum não confere (token errado?)" unless Digest::MD5.digest(packet.byteslice(0, 16) + token + data) == packet.byteslice(16, 16)

      { did: did, stamp: stamp, payload: decrypt(token, data).delete("\x00").force_encoding("UTF-8") }
    end

    def cipher(mode, token, data)
      key, iv = key_iv(token)
      c = OpenSSL::Cipher.new("aes-128-cbc").public_send(mode)
      c.key = key
      c.iv = iv
      c.update(data) + c.final
    rescue OpenSSL::Cipher::CipherError
      raise Error, "não deu para decifrar (token errado?)"
    end
  end
end
