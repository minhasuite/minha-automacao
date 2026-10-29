require "socket"

module Tuya
  # Conexão TCP com um aparelho Tuya (porta 6668): negocia a sessão (3.4/3.5),
  # lê o estado, manda dps e escuta os empurrões de status. Escrita protegida
  # por mutex (o ouvinte lê numa thread e o comando escreve de outra); leitura
  # só de uma thread por vez.
  class Connection
    PORT = 6668
    class Error < StandardError; end

    attr_reader :device_id, :protocol

    def self.open(**opts)
      conn = new(**opts).connect
      return conn unless block_given?

      begin
        yield conn
      ensure
        conn.close
      end
    end

    def initialize(host:, device_id:, local_key:, version:, port: PORT, timeout: 5)
      @host = host
      @port = port
      @device_id = device_id
      @timeout = timeout
      @protocol = Protocol.new(version, local_key)
      @seq = 0
      @buffer = "".b
      @write_lock = Mutex.new
    end

    def connect
      @socket = Socket.tcp(@host, @port, connect_timeout: @timeout)
      negotiate if protocol.session?
      self
    rescue SystemCallError, IOError, SocketError => e
      close
      raise Error, "sem conexão com #{@host}: #{e.message}"
    end

    def close
      @socket&.close
    rescue IOError
      nil
    ensure
      @socket = nil
    end

    def open? = !@socket.nil?

    # dps atuais do aparelho ({"1" => true, "19" => 120, …}).
    def status
      send_message(protocol.session? ? Protocol::DP_QUERY_NEW : Protocol::DP_QUERY, query_payload)
      wait_dps || raise(Error, "o aparelho não respondeu ao pedido de estado")
    end

    # Manda dps e devolve os dps que o aparelho confirmar (ou nil).
    def set(dps)
      write_dps(dps)
      wait_dps
    end

    def write_dps(dps)
      if protocol.session?
        send_message(Protocol::CONTROL_NEW, JSON.generate({ protocol: 5, t: Time.now.to_i, data: { dps: dps } }))
      else
        send_message(Protocol::CONTROL, JSON.generate({ devId: device_id, uid: device_id, t: Time.now.to_i.to_s, dps: dps }))
      end
    end

    def heartbeat = send_message(Protocol::HEART_BEAT, protocol.session? ? "{}" : JSON.generate({ gwId: device_id, devId: device_id }))

    # Próxima mensagem do aparelho (nil se nada chegou no tempo).
    def read(timeout = @timeout)
      deadline = monotonic + timeout
      loop do
        if (msg = take_message)
          return msg
        end

        left = deadline - monotonic
        return nil if left <= 0
        return nil unless @socket.wait_readable(left)

        chunk = @socket.read_nonblock(4096, exception: false)
        raise Error, "o aparelho fechou a conexão" if chunk.nil?

        @buffer << chunk unless chunk == :wait_readable
      end
    rescue SystemCallError, IOError => e
      raise Error, "conexão caiu: #{e.message}"
    end

    def send_message(cmd, payload)
      @write_lock.synchronize do
        raise Error, "conexão fechada" unless @socket

        @seq += 1
        @socket.write(protocol.pack(@seq, cmd, payload))
      end
    rescue SystemCallError, IOError => e
      raise Error, "conexão caiu: #{e.message}"
    end

    private

    def query_payload
      return "{}" if protocol.session?

      JSON.generate({ gwId: device_id, devId: device_id, uid: device_id, t: Time.now.to_i.to_s })
    end

    def negotiate
      nonce = OpenSSL::Random.random_bytes(16)
      send_message(Protocol::SESS_KEY_NEG_START, nonce)
      resp = nil
      3.times do
        resp = read
        break if resp.nil? || resp.cmd == Protocol::SESS_KEY_NEG_RESP
      end
      raise Error, "o aparelho não respondeu à negociação (local_key ou versão errada?)" unless resp&.cmd == Protocol::SESS_KEY_NEG_RESP

      finish = protocol.session_finish(nonce, resp.payload)
      # FINISH ainda vai com a local_key: troca a chave depois de mandar.
      session_key = protocol.key
      protocol.reset_key!
      send_message(Protocol::SESS_KEY_NEG_FINISH, finish)
      protocol.key = session_key
    end

    def wait_dps(timeout = @timeout)
      deadline = monotonic + timeout
      while (left = deadline - monotonic) > 0
        msg = read(left) or return nil
        dps = msg.dps
        return dps if dps.is_a?(Hash) && dps.any?
      end
      nil
    end

    def take_message
      msg, rest = protocol.unpack(@buffer)
      return nil unless msg

      @buffer = rest
      msg
    end

    def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end
end
