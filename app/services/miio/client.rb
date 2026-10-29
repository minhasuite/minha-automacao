require "socket"

module Miio
  # Cliente miIO/MIoT por UDP. Faz o hello (did e carimbo do aparelho) e manda
  # comandos JSON com id crescente; resposta com outro id é descartada.
  # Sem resposta: tenta de novo (o aparelho perde pacote) e refaz o hello.
  class Client
    PORT = 54_321
    class Error < StandardError; end

    def initialize(host:, token:, port: PORT, timeout: 3, retries: 2)
      @host = host
      @port = port
      @token = token.to_s.match?(/\A\h{32}\z/) ? [ token ].pack("H*") : token.to_s.b
      @timeout = timeout
      @retries = retries
      @id = rand(1..9000)
    end

    attr_reader :did

    def call(method, params = [])
      attempts = 0
      begin
        handshake if @stamp.nil?
        @id += 1
        request = { id: @id, method: method, params: params }.to_json
        reply = exchange(Protocol.encode(@token, did: @did, stamp: stamp_now, payload: request)) { |r| r[:payload] && JSON.parse(r[:payload])["id"] == @id }
        body = JSON.parse(reply[:payload])
        raise Error, "o aparelho recusou #{method}: #{body['error'].to_json}" if body["error"]

        body["result"]
      rescue Timeout::Error
        @stamp = nil
        retry if (attempts += 1) <= @retries
        raise Error, "#{@host} não respondeu"
      end
    end

    # props: [[siid, piid], ...] → { [siid, piid] => valor } (só o que veio com code 0).
    def get_properties(props)
      props.each_slice(15).each_with_object({}) do |slice, out|
        result = call("get_properties", slice.map { |s, p| { did: "p_#{s}_#{p}", siid: s, piid: p } })
        Array(result).each { |r| out[[ r["siid"], r["piid"] ]] = r["value"] if r["code"].to_i.zero? }
      end
    end

    def set_properties(values)
      result = call("set_properties", values.map { |(s, p), v| { did: "p_#{s}_#{p}", siid: s, piid: p, value: v } })
      bad = Array(result).reject { |r| r["code"].to_i.zero? }
      raise Error, "o aparelho recusou #{bad.map { |r| "#{r['siid']}.#{r['piid']}" }.join(', ')}" if bad.any?

      result
    end

    def action(siid, aiid, args = [])
      result = call("action", { did: "a_#{siid}_#{aiid}", siid: siid, aiid: aiid, in: args })
      raise Error, "o aparelho recusou a ação #{siid}.#{aiid} (code #{result['code']})" if result.is_a?(Hash) && result["code"].to_i.nonzero?

      result
    end

    def handshake
      reply = exchange(Protocol::HELLO) { |r| r[:payload].nil? }
      @did = reply[:did]
      @stamp = reply[:stamp]
      @stamp_at = monotonic
      self
    end

    private

    def stamp_now = @stamp + (monotonic - @stamp_at).to_i + 1

    def exchange(packet)
      socket = UDPSocket.new
      socket.send(packet, 0, @host, @port)
      deadline = monotonic + @timeout
      loop do
        left = deadline - monotonic
        raise Timeout::Error if left <= 0 || !socket.wait_readable(left)

        reply = Protocol.decode(@token, socket.recvfrom(4096).first)
        return reply if yield(reply)
      end
    rescue SystemCallError, SocketError => e
      raise Error, "sem conexão com #{@host}: #{e.message}"
    rescue JSON::ParserError
      raise Error, "resposta ilegível de #{@host}"
    ensure
      socket&.close
    end

    def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end
end
