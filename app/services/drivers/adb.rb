module Drivers
  # Android TV / Fire TV / Google TV por ADB na rede (Pacote 1, porta 5555;
  # "Depuração de rede" ligada na TV). Protocolo ADB (cabeçalho de 24 bytes:
  # CNXN, AUTH, OPEN, WRTE, OKAY, CLSE) com uma chave RSA própria da
  # integração, gerada aqui e guardada cifrada. Na primeira vez a TV recusa
  # a assinatura, recebe a chave pública e pergunta "Permitir depuração?":
  # esse é o pareamento. Teclas por `input keyevent`; estado por `dumpsys`.
  class Adb < MediaLan
    PORT = 5555
    KEYS = { "on" => 224, "off" => 223, "volume_up" => 24, "volume_down" => 25, "mute" => 164,
             "resume" => 126, "pause" => 127, "next" => 87, "previous" => 88 }.freeze
    SUPPORTS = (KEYS.keys + %w[play_media]).freeze
    STATE = "dumpsys power | grep -m1 mWakefulness=; dumpsys window | grep -E -m2 'mCurrentFocus|mFocusedApp'".freeze

    class << self
      def client(device, **) = Client.new(host(device), port(device, PORT), key(secrets_owner(device)), **)

      def read(device) = state(client(device).shell(STATE))

      def state(out)
        awake = out[/mWakefulness=(\w+)/, 1] == "Awake"
        app = out[%r{(?:mCurrentFocus|mFocusedApp)=.*?\s([A-Za-z][\w.]*)/}, 1]
        { "state" => awake ? "on" : "off", "app" => (app if awake) }.compact
      end

      def run(device, command, value)
        cmd = command == "play_media" ? "am start -a android.intent.action.VIEW -d #{Shellwords.escape(value)}" : "input keyevent #{KEYS.fetch(command)}"
        client(device).shell(cmd)
      end

      # Chave RSA da integração (gerada uma vez, cifrada).
      def key(integration)
        pem = integration.secrets["adb_key"] || OpenSSL::PKey::RSA.new(2048).to_pem.tap { |k| integration.merge_secrets!("adb_key" => k) }
        OpenSSL::PKey::RSA.new(pem)
      end

      # Chave pública no formato do Android (struct RSAPublicKey do mincrypt, base64 + nome).
      def public_key(rsa, name = "minha-automacao")
        n = rsa.n.to_i
        words = rsa.n.num_bits / 32
        r32 = 1 << 32
        n0inv = (r32 - rsa.n.mod_inverse(OpenSSL::BN.new(r32)).to_i) % r32
        rr = (1 << (words * 64)) % n
        le = ->(x) { [ x.to_s(16).rjust(words * 8, "0") ].pack("H*").reverse }
        "#{Base64.strict_encode64([ words, n0inv ].pack('VV') + le.call(n) + le.call(rr) + [ rsa.e.to_i ].pack('V'))} #{name}"
      end
    end

    class Client
      CMD = { cnxn: 0x4e584e43, auth: 0x48545541, open: 0x4e45504f, okay: 0x59414b4f, clse: 0x45534c43, wrte: 0x45545257 }.freeze
      TOKEN = 1
      SIGNATURE = 2
      PUBLIC = 3

      def initialize(host, port, key, timeout: 5, pair_timeout: 5)
        @host = host
        @port = port
        @key = key
        @timeout = timeout
        @pair_timeout = pair_timeout
      end

      # Roda um comando no shell e devolve a saída.
      def shell(command)
        connect
        packet(:open, 1, 0, "shell:#{command}\0")
        out = +"".b
        loop do
          cmd, arg0, _, data = read_packet(@timeout)
          case cmd
          when :wrte
            out << data
            packet(:okay, 1, arg0, "")
          when :clse then break
          end
        end
        out.force_encoding("UTF-8").scrub
      ensure
        @sock&.close
      end

      private

      def connect
        @sock = Socket.tcp(@host, @port, connect_timeout: @timeout)
        packet(:cnxn, 0x01000000, 4096, "host::\0")
        signed = sent_public = false
        loop do
          cmd, arg0, _, data = read_packet(sent_public ? @pair_timeout : @timeout)
          return if cmd == :cnxn
          raise Adb::Error, "Resposta inesperada do ADB." unless cmd == :auth && arg0 == TOKEN
          raise Adb::Error, "A TV recusou a chave. Permita a depuração na tela da TV e tente de novo." if sent_public

          if signed
            packet(:auth, PUBLIC, 0, "#{Adb.public_key(@key)}\0")
            sent_public = true
          else
            packet(:auth, SIGNATURE, 0, @key.sign_raw("sha1", data))
            signed = true
          end
        end
      end

      def packet(cmd, arg0, arg1, data)
        data = data.b
        code = CMD.fetch(cmd)
        @sock.write([ code, arg0, arg1, data.bytesize, data.bytes.sum & 0xFFFF_FFFF, code ^ 0xFFFF_FFFF ].pack("V6") + data)
      end

      def read_packet(timeout)
        code, arg0, arg1, len = read_exact(24, timeout).unpack("V4")
        [ CMD.key(code), arg0, arg1, read_exact(len, timeout) ]
      end

      def read_exact(n, timeout)
        out = +"".b
        while out.bytesize < n
          raise Adb::Error, "A TV não respondeu (confira a depuração de rede ou permita o acesso na tela)." unless @sock.wait_readable(timeout)

          chunk = @sock.read_nonblock(n - out.bytesize, exception: false)
          raise Adb::Error, "A TV fechou a conexão ADB." if chunk.nil?

          out << chunk unless chunk.is_a?(Symbol)
        end
        out
      end
    end
  end
end
