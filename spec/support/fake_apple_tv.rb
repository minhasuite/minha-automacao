require_relative "fake_hap_accessory"

# resto2: Apple TV de mentira (Companion) em 127.0.0.1. O pair-setup e o
# pair-verify são os do acessório HomeKit de mentira (mesmo HAP, PIN de 4
# dígitos); aqui só o transporte (quadros OPACK) e as chaves da sessão
# Companion mudam. Guarda o que chegou: teclas (_hidC), mídia (_mcc) e apps.
class FakeAppleTv < FakeHapAccessory
  attr_reader :hid, :mcc, :launched, :started, :asked

  def initialize(asleep: false)
    @hid = []
    @mcc = []
    @launched = []
    @asked = []
    @asleep = asleep
    super(pin: "1234")
  end

  private

  def serve(sock)
    @sock, @rk, @wk, @in, @out = sock, nil, nil, 0, 0
    loop do
      (type, body = frame_in) or break
      msg = Companion::Opack.unpack(body)
      case type
      when Companion::PS_START, Companion::PS_NEXT
        @started = true
        frame_out(Companion::PS_NEXT, "_pd" => pair_setup(Hap::Tlv.decode(msg["_pd"])))
      when Companion::PV_START, Companion::PV_NEXT
        frame_out(Companion::PV_NEXT, "_pd" => pair_verify(Hap::Tlv.decode(msg["_pd"])))
        next unless @pending

        @pending = nil
        @rk, @wk = Hap.hkdf(@shared, "", "ClientEncrypt-main"), Hap.hkdf(@shared, "", "ServerEncrypt-main")
      when Companion::E_OPACK
        frame_out(Companion::E_OPACK, "_x" => 1) # evento solto no meio (o cliente ignora)
        frame_out(Companion::E_OPACK, "_x" => msg["_x"], "_t" => 3, "_c" => answer(msg["_i"], msg["_c"]))
      end
    end
  rescue IOError, SystemCallError, Hap::Error, Companion::Error
    nil
  ensure
    sock.close
  end

  def answer(id, c)
    @asked << id
    case id
    when "_hidC" then @hid << [ c["_hidC"], c["_hBtS"] ]
    when "_mcc" then @mcc << c["_mcc"]
    when "_launchApp" then @launched << (c["_bundleID"] || c["_urlS"])
    when "FetchAttentionState" then return { "state" => @asleep ? 1 : 3 }
    when "FetchLaunchableApplicationsEvent" then return { "com.netflix.Netflix" => "Netflix", "com.apple.TVWatchList" => "TV" }
    end
    {}
  end

  def nonce(n) = [ n ].pack("Q<") + ("\0" * 4).b

  def frame_in
    head = @sock.read(4) or return nil
    body = @sock.read(("\0".b + head.byteslice(1, 3)).unpack1("N"))
    return [ head.getbyte(0), body ] unless @rk

    [ head.getbyte(0), Hap.open(@rk, nonce(@in), body, head) ].tap { @in += 1 }
  end

  def frame_out(type, obj)
    body = Companion::Opack.pack(obj)
    return @sock.write([ type ].pack("C") + [ body.bytesize ].pack("N")[1, 3] + body) unless @wk

    head = [ type ].pack("C") + [ body.bytesize + 16 ].pack("N")[1, 3]
    @sock.write(head + Hap.seal(@wk, nonce(@out), body, head))
    @out += 1
  end
end
