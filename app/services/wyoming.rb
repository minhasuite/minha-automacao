require "socket"
require "open3"

# Protocolo Wyoming (ondaB1, B6; o do HA para voz local): Whisper (STT),
# Piper (TTS), openWakeWord (palavra de ativação) e o wyoming-satellite. Cada
# evento é uma linha JSON {type, data_length?, payload_length?} seguida dos
# dados (JSON) e do payload (áudio PCM). Conexão TCP curta por pedido, com
# timeout em tudo. Erro = Wyoming::Error (é um Ai::Client::Error: o pipeline
# e as telas tratam igual à voz da nuvem).
module Wyoming
  class Error < Ai::Client::Error; end

  VERSION = "1.5.4".freeze
  RATE = 16_000
  WIDTH = 2
  CHANNELS = 1
  CHUNK = 2048 # bytes por audio-chunk (1024 amostras de 16 bits)
  MAX_LINE = 64.kilobytes
  MAX_PAYLOAD = 20.megabytes
  PORTS = { stt: 10_300, tts: 10_200, wake: 10_400, satellite: 10_700 }.freeze

  module_function

  def open(host, port, timeout: 10)
    conn = Connection.new(Socket.tcp(host.to_s, port.to_i, connect_timeout: timeout), timeout)
    yield conn
  rescue SystemCallError, SocketError, IOError => e
    raise Error, "Wyoming #{host}:#{port}: #{e.message.truncate(120)}"
  ensure
    conn&.close
  end

  # → {"asr" => [...], "tts" => [...], "wake" => [...], "satellite" => {...}} (o que o servidor sabe fazer).
  def describe(host, port, timeout: 5)
    open(host, port, timeout: timeout) do |c|
      c.write("describe")
      c.until("info").last
    end
  end

  # PCM 16 kHz/16 bits/mono (ou o formato dado) → texto.
  def transcribe(host, port, pcm, language: nil, model: nil, rate: RATE, width: WIDTH, channels: CHANNELS, timeout: 60)
    open(host, port, timeout: timeout) do |c|
      c.write("transcribe", { "language" => language.to_s[0, 2].presence, "name" => model.presence }.compact)
      c.stream(pcm, rate, width, channels)
      c.until("transcript").last["text"].to_s.dup.force_encoding(Encoding::UTF_8).scrub.squish
    end
  end

  # Texto → {data: WAV, media_type:, pcm:, rate:, width:, channels:}.
  def synthesize(host, port, text, voice: nil, timeout: 60)
    open(host, port, timeout: timeout) do |c|
      c.write("synthesize", { "text" => text.to_s.first(4000), "voice" => ({ "name" => voice } if voice.present?) }.compact)
      fmt = c.until("audio-start").last
      pcm = "".b
      loop do
        event = c.read or raise Error, "Wyoming: a fala parou no meio."
        type, _data, payload = event
        break if type == "audio-stop"

        pcm << payload.to_s if type == "audio-chunk"
        raise Error, "Wyoming: fala grande demais." if pcm.bytesize > MAX_PAYLOAD
      end
      rate, width, channels = fmt.values_at("rate", "width", "channels").map(&:to_i)
      { data: wav(pcm, rate, width, channels), media_type: "audio/wav", pcm: pcm, rate: rate, width: width, channels: channels }
    end
  end

  # PCM → nome da palavra de ativação ouvida ou nil.
  def detect(host, port, pcm, names: [], rate: RATE, width: WIDTH, channels: CHANNELS, timeout: 30)
    open(host, port, timeout: timeout) do |c|
      c.write("detect", { "names" => names.presence }.compact)
      c.stream(pcm, rate, width, channels)
      type, data = c.until("detection", "not-detected")
      type == "detection" ? data["name"].to_s.presence || "wake" : nil
    end
  end

  # WAV (RIFF, PCM) → [pcm, rate, width, channels]; outro formato → Error.
  def pcm_of(bytes, media_type = nil)
    b = bytes.to_s.b
    # m4a do app antigo, webm/ogg do navegador, WAV que não é PCM: o ffmpeg passa para PCM 16 kHz mono.
    return to_pcm(b, media_type) unless b[0, 4] == "RIFF" && b[8, 4] == "WAVE" && pcm_wav?(b)

    pos = 12
    fmt = nil
    while pos + 8 <= b.bytesize
      id = b[pos, 4]
      size = b[pos + 4, 4].unpack1("V")
      body = b[pos + 8, size].to_s
      fmt = body.unpack("vvVVvv") if id == "fmt "
      if id == "data"
        raise Error, "WAV sem formato." unless fmt && fmt[0] == 1

        return [ body, fmt[2], fmt[5] / 8, fmt[1] ]
      end
      pos += 8 + size + (size.odd? ? 1 : 0)
    end
    raise Error, "WAV sem áudio."
  end

  def pcm_wav?(b) = (i = b.index("fmt ")) && b[i + 8, 2].to_s.unpack1("v") == 1

  def to_pcm(bytes, media_type)
    out, err, status = Open3.capture3("ffmpeg", "-hide_banner", "-loglevel", "error", "-i", "pipe:0", "-f", "s16le", "-ac", "1", "-ar", RATE.to_s, "pipe:1",
                                      stdin_data: bytes, binmode: true)
    raise Error, "Não deu para ler o áudio (#{media_type.presence || 'formato desconhecido'}): #{err.to_s.strip.truncate(120)}" unless status.success? && out.bytesize.positive?

    [ out, RATE, 2, 1 ]
  rescue Errno::ENOENT
    raise Error, "Wyoming precisa de áudio WAV (PCM) e o ffmpeg não está instalado; veio #{media_type.presence || 'outro formato'}."
  end

  def wav(pcm, rate, width, channels)
    header = [ "RIFF", 36 + pcm.bytesize, "WAVE", "fmt ", 16, 1, channels, rate, rate * width * channels, width * channels, width * 8, "data", pcm.bytesize ]
    header.pack("a4Va4a4VvvVVvva4V") + pcm.b
  end

  def chunks(pcm)
    b = pcm.to_s.b
    (0...b.bytesize).step(CHUNK) { |i| yield b.byteslice(i, CHUNK) }
  end

  # Volume (RMS) de um trecho PCM de 16 bits, para o fim da fala (VAD simples).
  def rms(pcm)
    samples = pcm.unpack("s<*")
    return 0 if samples.empty?

    Math.sqrt(samples.sum { |s| s * s } / samples.size.to_f).round
  end

  class Connection
    def initialize(sock, timeout)
      @sock = sock
      @timeout = timeout
      @buf = "".b
    end

    def close = @sock.close
    def io = @sock

    def write(type, data = {}, payload = nil)
      body = data.present? ? data.to_json.b : "".b
      header = { "type" => type, "version" => VERSION, "data_length" => (body.bytesize if body.bytesize.positive?),
                 "payload_length" => (payload.bytesize if payload) }.compact
      @sock.write(header.to_json.b + "\n" + body + payload.to_s.b)
    end

    # audio-start, audio-chunk..., audio-stop.
    def stream(pcm, rate, width, channels)
      fmt = { "rate" => rate, "width" => width, "channels" => channels }
      write("audio-start", fmt)
      Wyoming.chunks(pcm) { |part| write("audio-chunk", fmt, part) }
      write("audio-stop")
    end

    # Próximo evento [tipo, dados, payload] ou nil (passou o tempo, ou fechou).
    def read(timeout = @timeout)
      line = read_line(timeout) or return
      header = JSON.parse(line)
      data = header["data"].is_a?(Hash) ? header["data"] : {}
      data = data.merge(JSON.parse(read_bytes(header["data_length"].to_i, timeout))) if header["data_length"].to_i.positive?
      length = header["payload_length"].to_i
      raise Error, "Wyoming: payload grande demais." if length > MAX_PAYLOAD

      [ header["type"].to_s, data, (read_bytes(length, timeout) if length.positive?) ]
    rescue JSON::ParserError
      raise Error, "Wyoming: resposta inválida."
    end

    # Lê até um dos tipos pedidos (o resto é ignorado; "error" vira Error).
    def until(*types)
      loop do
        event = read or raise Error, "Wyoming: sem resposta (#{types.join('/')})."
        type, data = event
        raise Error, "Wyoming: #{data['text'].to_s.truncate(120)}" if type == "error"
        return [ type, data ] if types.include?(type)
      end
    end

    private

    def read_line(timeout)
      deadline = clock + timeout
      until (i = @buf.index("\n"))
        raise Error, "Wyoming: linha grande demais." if @buf.bytesize > MAX_LINE
        return unless fill(deadline)
      end
      line = @buf.byteslice(0, i)
      @buf = @buf.byteslice(i + 1..)
      line
    end

    def read_bytes(n, timeout)
      deadline = clock + timeout
      while @buf.bytesize < n
        fill(deadline) or raise Error, "Wyoming: a mensagem parou no meio."
      end
      out = @buf.byteslice(0, n)
      @buf = @buf.byteslice(n..)
      out
    end

    def fill(deadline)
      left = deadline - clock
      return false if left <= 0 || !IO.select([ @sock ], nil, nil, left)

      @buf << @sock.read_nonblock(64.kilobytes)
      true
    rescue IO::WaitReadable
      true
    rescue EOFError
      false
    end

    def clock = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end
end
