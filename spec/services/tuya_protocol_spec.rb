require "rails_helper"

# Protocolo Tuya local sem rede: quadros montados à mão (como o aparelho
# manda, com código de retorno) e conferidos contra o Tuya::Protocol.
RSpec.describe Tuya::Protocol do
  let(:key) { "0123456789abcdef" }

  def aes_ecb(data, k = key, pad: true)
    c = OpenSSL::Cipher.new("aes-128-ecb").encrypt
    c.key = k
    c.padding = 0 unless pad
    c.update(data) + c.final
  end

  def frame_55aa(seq, cmd, payload, hmac_key: nil)
    header = [ 0x55AA, seq, cmd, payload.bytesize + (hmac_key ? 32 : 4) + 4 ].pack("N4")
    check = hmac_key ? OpenSSL::HMAC.digest("SHA256", hmac_key, header + payload) : [ Zlib.crc32(header + payload) ].pack("N")
    header + payload + check + [ 0xAA55 ].pack("N")
  end

  def frame_6699(seq, cmd, plain, k)
    iv = "abcdefghijkl"
    header = [ 0x6699, 0, seq, cmd, 12 + plain.bytesize + 16 ].pack("NnN3")
    c = OpenSSL::Cipher.new("aes-128-gcm").encrypt
    c.key = k
    c.iv = iv
    c.auth_data = header.byteslice(4..)
    ct = c.update(plain) + c.final
    header + iv + ct + c.auth_tag + [ 0x9966 ].pack("N")
  end

  it "3.3: monta o CONTROL com cabeçalho e o DP_QUERY sem, com CRC" do
    p = described_class.new("3.3", key)
    json = '{"dps":{"1":true}}'
    expect(p.pack(1, 7, json)).to eq(frame_55aa(1, 7, "3.3".b + ("\0" * 12) + aes_ecb(json)))
    expect(p.pack(2, 10, "{}")).to eq(frame_55aa(2, 10, aes_ecb("{}")))
  end

  it "3.3: lê o empurrão de status do aparelho (código de retorno + cabeçalho + AES)" do
    p = described_class.new("3.3", key)
    data = frame_55aa(5, 8, [ 0 ].pack("N") + "3.3".b + ("\0" * 12) + aes_ecb('{"dps":{"20":true,"22":500},"t":1}'))
    msg, rest = p.unpack("lixo".b + data + "meio".b)
    expect([ msg.cmd, msg.retcode, msg.dps ]).to eq([ 8, 0, { "20" => true, "22" => 500 } ])
    expect(rest).to eq("meio".b)
    expect(p.unpack(data.byteslice(0, 20))).to be_nil
    expect { p.unpack(data.dup.tap { |d| d.setbyte(20, d.getbyte(20) ^ 1) }) }.to raise_error(described_class::Error, /CRC/)
  end

  it "3.3: erro em texto puro e ack vazio" do
    p = described_class.new("3.3", key)
    msg, = p.unpack(frame_55aa(1, 10, [ 1 ].pack("N") + "json obj data unvalid"))
    expect([ msg.retcode, msg.payload, msg.dps ]).to eq([ 1, "json obj data unvalid", nil ])
    msg, = p.unpack(frame_55aa(2, 7, [ 0 ].pack("N")))
    expect(msg.payload).to eq("")
  end

  it "3.1: CONTROL em base64 assinado por md5; status cifrado ou puro" do
    p = described_class.new("3.1", key)
    json = '{"dps":{"1":false}}'
    b64 = Base64.strict_encode64(aes_ecb(json))
    md5 = Digest::MD5.hexdigest("data=#{b64}||lpv=3.1||#{key}")[8, 16]
    expect(p.pack(1, 7, json)).to eq(frame_55aa(1, 7, "3.1#{md5}#{b64}".b))
    expect(p.pack(2, 10, "{}")).to eq(frame_55aa(2, 10, "{}".b))
    msg, = p.unpack(frame_55aa(3, 8, [ 0 ].pack("N") + "3.1#{md5}#{b64}".b))
    expect(msg.dps).to eq({ "1" => false })
    msg, = p.unpack(frame_55aa(4, 10, [ 0 ].pack("N") + '{"dps":{"1":true}}'))
    expect(msg.dps).to eq({ "1" => true })
  end

  it "3.4: negocia a chave de sessão e troca quadros com HMAC" do
    p = described_class.new("3.4", key)
    local_nonce = "L" * 16
    remote_nonce = "R" * 16
    start = p.pack(1, 3, local_nonce)
    expect(start).to eq(frame_55aa(1, 3, aes_ecb(local_nonce), hmac_key: key))

    resp = remote_nonce + OpenSSL::HMAC.digest("SHA256", key, local_nonce)
    msg, = p.unpack(frame_55aa(1, 4, [ 0 ].pack("N") + aes_ecb(resp), hmac_key: key))
    finish = p.session_finish(local_nonce, msg.payload)
    expect(finish).to eq(OpenSSL::HMAC.digest("SHA256", key, remote_nonce))
    session = aes_ecb(local_nonce.bytes.zip(remote_nonce.bytes).map { |a, b| a ^ b }.pack("C*"), pad: false)
    expect(p.key).to eq(session)

    json = '{"protocol":5,"t":1,"data":{"dps":{"1":true}}}'
    expect(p.pack(2, 13, json)).to eq(frame_55aa(2, 13, aes_ecb("3.4".b + ("\0" * 12) + json, session), hmac_key: session))
    push = frame_55aa(9, 8, [ 0 ].pack("N") + aes_ecb("3.4".b + ("\0" * 12) + '{"protocol":4,"t":1,"data":{"dps":{"2":false}}}', session), hmac_key: session)
    expect(p.unpack(push).first.dps).to eq({ "2" => false })
    expect { p.session_finish(local_nonce, remote_nonce + ("x" * 32)) }.to raise_error(described_class::Error, /local_key/)
  end

  it "3.5: AES-GCM com o cabeçalho como AAD e chave de sessão por GCM" do
    p = described_class.new("3.5", key)
    local_nonce = "L" * 16
    remote_nonce = "R" * 16
    resp = remote_nonce + OpenSSL::HMAC.digest("SHA256", key, local_nonce)
    msg, = p.unpack(frame_6699(1, 4, [ 0 ].pack("N") + resp, key))
    p.session_finish(local_nonce, msg.payload)
    c = OpenSSL::Cipher.new("aes-128-gcm").encrypt
    c.key = key
    c.iv = local_nonce.byteslice(0, 12)
    session = c.update(local_nonce.bytes.zip(remote_nonce.bytes).map { |a, b| a ^ b }.pack("C*")) + c.final
    expect(p.key).to eq(session)

    push = frame_6699(7, 8, [ 0 ].pack("N") + "3.5".b + ("\0" * 12) + '{"protocol":4,"data":{"dps":{"1":true,"20":2207}}}', session)
    msg, rest = p.unpack(push)
    expect([ msg.seq, msg.cmd, msg.dps, rest ]).to eq([ 7, 8, { "1" => true, "20" => 2207 }, "".b ])

    # O que o cliente manda o aparelho abre com a mesma chave.
    sent = p.pack(3, 13, '{"x":1}')
    other = described_class.new("3.5", key).tap { |o| o.key = session }
    expect(other.unpack(sent).first.payload).to eq('{"x":1}')
    sent.setbyte(30, sent.getbyte(30) ^ 1)
    expect { other.unpack(sent) }.to raise_error(described_class::Error, /GCM/)
  end

  it "recusa versão e chave inválidas" do
    expect { described_class.new("3.2", key) }.to raise_error(described_class::Error)
    expect { described_class.new("3.3", "curta") }.to raise_error(described_class::Error)
  end
end
