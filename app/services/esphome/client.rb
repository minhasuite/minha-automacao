require "socket"

module Esphome
  # Cliente da API nativa do ESPHome (TCP 6053, protobuf). Sem chave: quadro
  # 0x00 + varint(tamanho) + varint(tipo) + dados. Com a chave de
  # criptografia: Noise (Esphome::Noise), quadro 0x01 + tamanho (2 bytes) e,
  # dentro do cifrado, tipo (2 bytes) + tamanho (2 bytes) + dados. Responde
  # sozinho ao ping, à hora e ao pedido de desconexão do aparelho.
  class Client
    HELLO, CONNECT, DISCONNECT_REQ, DISCONNECT_RES, PING_REQ, PING_RES = 1, 3, 5, 6, 7, 8
    DEVICE_INFO, LIST, LIST_DONE, SUBSCRIBE = 9, 11, 19, 20
    GET_TIME_REQ, GET_TIME_RES = 36, 37
    API_VERSION = [ 1, 10 ].freeze

    # Tipo da resposta da lista → tipo de entidade; e o do estado.
    LIST_TYPES = { 12 => "binary_sensor", 13 => "cover", 15 => "light", 16 => "sensor", 17 => "switch",
                   18 => "text_sensor", 49 => "number", 61 => "button" }.freeze
    STATE_TYPES = { 21 => "binary_sensor", 22 => "cover", 24 => "light", 25 => "sensor", 26 => "switch",
                    27 => "text_sensor", 50 => "number" }.freeze
    COMMANDS = { "cover" => 30, "light" => 32, "switch" => 33, "number" => 51, "button" => 62 }.freeze
    # Campos próprios de cada entidade na lista (os 4 primeiros são comuns:
    # object_id, key, name, unique_id).
    FIELDS = {
      "binary_sensor" => { device_class: 5, status: 6, disabled: 7 },
      "cover" => { supports_position: 6, device_class: 8, disabled: 9 },
      "light" => { legacy_brightness: 5, color_modes: 12, disabled: 13 },
      "sensor" => { unit: 6, decimals: 7, device_class: 9, state_class: 10, disabled: 12 },
      "switch" => { disabled: 7, device_class: 9 },
      "text_sensor" => { disabled: 6, device_class: 8 },
      "number" => { min: 6, max: 7, step: 8, disabled: 9, unit: 11, device_class: 13 },
      "button" => { disabled: 6, device_class: 8 }
    }.freeze
    FLOATS = %i[min max step].freeze
    BOOLS = %i[disabled status supports_position legacy_brightness].freeze
    STRINGS = %i[device_class unit].freeze

    def self.open(**)
      client = new(**).connect
      yield client
    ensure
      client&.close
    end

    def initialize(host:, port: 6053, key: nil, password: nil, timeout: 5)
      @host = host
      @port = port.to_i.positive? ? port.to_i : 6053
      @key = key.presence
      @password = password.to_s
      @timeout = timeout
    end

    def connect
      @sock = Socket.tcp(@host, @port, connect_timeout: @timeout)
      @frames = @key ? NoiseFrames.new(@sock, Noise.psk(@key), @timeout) : PlainFrames.new(@sock, @timeout)
      @frames.handshake
      hello = request(HELLO, [ [ 1, :string, "Minha Automação" ], [ 2, :varint, API_VERSION[0] ], [ 3, :varint, API_VERSION[1] ] ], 2)
      @server = Proto.string(hello[3]&.first)
      res = request(CONNECT, [ [ 1, :string, @password.presence ] ], 4)
      raise Integrations.auth(Error.new("Senha da API recusada pelo aparelho.")) if res[1]&.first.to_i == 1

      self
    rescue SystemCallError, SocketError, IOError => e
      close
      raise Error, "Sem conexão com #{@host}:#{@port}: #{e.message}"
    end

    def close
      @frames&.write(DISCONNECT_REQ, "".b)
    rescue StandardError
      nil
    ensure
      @sock&.close
      @sock = nil
    end

    def send_message(type, fields = []) = @frames.write(type, Proto.encode(fields))

    # Próxima mensagem do aparelho [tipo, campos] ou nil depois de `timeout`.
    def read(timeout = @timeout)
      loop do
        msg = @frames.read(timeout) or return nil
        type, data = msg
        case type
        when PING_REQ then send_message(PING_RES)
        when GET_TIME_REQ then send_message(GET_TIME_RES, [ [ 1, :fixed32, Time.now.to_i ] ])
        when DISCONNECT_REQ
          send_message(DISCONNECT_RES)
          raise Error, "O aparelho encerrou a conexão."
        else return [ type, Proto.decode(data) ]
        end
      end
    end

    def request(type, fields, expect)
      send_message(type, fields)
      loop do
        msg = read or raise Error, "O aparelho não respondeu."
        got, f = msg
        return f if got == expect
      end
    end

    def device_info
      f = request(DEVICE_INFO, [], 10)
      { "name" => Proto.string(f[2]&.first), "mac" => Proto.string(f[3]&.first), "version" => Proto.string(f[4]&.first),
        "model" => Proto.string(f[6]&.first), "manufacturer" => Proto.string(f[12]&.first), "friendly_name" => Proto.string(f[13]&.first) }.compact_blank
    end

    # → [{"kind", "key", "object_id", "name", ...}] sem as desligadas por padrão e sem o "status".
    def list_entities
      send_message(LIST)
      list = []
      loop do
        msg = read or raise Error, "A lista de entidades não terminou."
        type, f = msg
        break if type == LIST_DONE

        kind = LIST_TYPES[type] or next
        list << entity(kind, f)
      end
      list.reject { |e| e[:disabled] || e[:status] }
    end

    def subscribe_states = send_message(SUBSCRIBE)

    # Mensagem de estado → [chave, tipo, campos] (nil se não for estado).
    def self.state_of(type, fields)
      kind = STATE_TYPES[type] or return
      [ Proto.fixed32(fields[1]&.first), kind, fields ]
    end

    # Estados durante `seconds` (ou até ter todas as `keys`): {chave → [tipo, campos]}.
    def states(seconds, keys = nil)
      limit = monotonic + seconds
      out = {}
      while (left = limit - monotonic).positive?
        msg = read(left) or break
        type, f = msg
        key, kind, fields = self.class.state_of(type, f)
        out[key] = [ kind, fields ] if key
        break if keys && (keys - out.keys).empty?
      end
      out
    end

    # Comando numa entidade ({kind, key, field}) com o valor do ponto.
    def command(entity, value)
      key = [ 1, :fixed32, entity["key"].to_i ]
      fields = case entity["kind"]
      when "switch" then [ key, [ 2, :bool, value ] ]
      when "light"
        entity["field"] == "brightness" ? [ key, [ 2, :bool, true ], [ 3, :bool, value.to_f.positive? ], [ 4, :bool, true ], [ 5, :float, value.to_f / 100 ] ] : [ key, [ 2, :bool, true ], [ 3, :bool, value ] ]
      when "cover"
        position = entity["position"] ? value.to_f / 100 : (value.to_f >= 50 ? 1.0 : 0.0)
        [ key, [ 4, :bool, true ], [ 5, :float, position ] ]
      when "number" then [ key, [ 2, :float, value.to_f ] ]
      when "button" then [ key ]
      else raise Error, "Entidade #{entity['kind']} não recebe comando."
      end
      send_message(COMMANDS.fetch(entity["kind"]), fields)
    end

    private

    def entity(kind, f)
      e = { kind: kind, key: Proto.fixed32(f[2]&.first), object_id: Proto.string(f[1]&.first), name: Proto.string(f[3]&.first),
            unique_id: Proto.string(f[4]&.first) }
      FIELDS.fetch(kind).each do |name, num|
        raw = f[num]
        next if raw.empty?

        e[name] = if FLOATS.include?(name) then Proto.float(raw.first)
        elsif STRINGS.include?(name) then Proto.string(raw.first).presence
        elsif name == :color_modes then raw.flat_map { |r| r.is_a?(String) ? varints(r) : [ r ] } # repetido "packed"
        elsif BOOLS.include?(name) then raw.first == 1
        else raw.first
        end
      end
      e
    end

    def varints(bytes)
      pos = 0
      out = []
      while pos < bytes.bytesize
        n, pos = Proto.read_varint(bytes, pos)
        out << n
      end
      out
    end

    def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end

  # Leitura exata do socket com prazo (comum aos dois quadros).
  module SocketIO
    # n bytes; nil se nada chegou no prazo (só no começo da mensagem).
    def read_exact(n, timeout)
      buf = +"".b
      limit = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
      while buf.bytesize < n
        left = limit - Process.clock_gettime(Process::CLOCK_MONOTONIC)
        unless left.positive? && IO.select([ @sock ], nil, nil, left)
          return nil if buf.empty?

          raise Error, "O aparelho parou no meio da mensagem."
        end
        chunk = @sock.read_nonblock(n - buf.bytesize, exception: false)
        raise Error, "O aparelho fechou a conexão." if chunk.nil?

        buf << chunk unless chunk.is_a?(Symbol)
      end
      buf
    end

    def need(n) = read_exact(n, @timeout) || raise(Error, "O aparelho parou no meio da mensagem.")
  end

  # Quadro sem criptografia.
  class PlainFrames
    include SocketIO

    def initialize(sock, timeout)
      @sock = sock
      @timeout = timeout
    end

    def handshake = nil

    def write(type, data) = @sock.write("\x00".b + Proto.varint(data.bytesize) + Proto.varint(type) + data)

    def read(timeout)
      first = read_exact(1, timeout) or return nil
      raise Integrations.auth(Error.new("O aparelho usa criptografia: informe a chave da API.")) if first == "\x01".b
      raise Error, "Resposta inválida do aparelho." unless first == "\x00".b

      size = varint
      type = varint
      [ type, size.zero? ? "".b : need(size) ]
    end

    private

    def varint
      n = 0
      shift = 0
      loop do
        byte = need(1).getbyte(0)
        n |= (byte & 0x7F) << shift
        return n if byte < 0x80

        shift += 7
      end
    end
  end

  # Quadro com Noise (chave de criptografia da API).
  class NoiseFrames
    include SocketIO

    def initialize(sock, psk, timeout)
      @sock = sock
      @timeout = timeout
      @noise = Noise.new(psk)
    end

    def handshake
      frame("".b) # hello do Noise
      frame("\x00".b + @noise.write_first)
      hello = read_frame(@timeout) or raise Error, "O aparelho não respondeu ao handshake."
      raise Error, "O aparelho não fala o protocolo com criptografia." unless hello.getbyte(0) == 1

      reply = read_frame(@timeout) or raise Error, "O aparelho não terminou o handshake."
      raise Integrations.auth(Error.new("Chave recusada: #{reply.byteslice(1..).force_encoding('UTF-8').scrub}")) unless reply.getbyte(0).zero?

      @noise.read_second(reply.byteslice(1..))
    end

    def write(type, data) = frame(@noise.sender.encrypt("".b, [ type, data.bytesize ].pack("nn") + data))

    def read(timeout)
      data = read_frame(timeout) or return nil
      plain = @noise.receiver.decrypt("".b, data)
      type, size = plain.unpack("nn")
      [ type, plain.byteslice(4, size) ]
    end

    private

    def frame(payload) = @sock.write("\x01".b + [ payload.bytesize ].pack("n") + payload)

    def read_frame(timeout)
      head = read_exact(3, timeout) or return nil
      raise Integrations.auth(Error.new("O aparelho não usa criptografia: deixe a chave vazia.")) if head.getbyte(0).zero?
      raise Error, "Resposta inválida do aparelho." unless head.getbyte(0) == 1

      size = head.byteslice(1, 2).unpack1("n")
      size.zero? ? "".b : need(size)
    end
  end
end
