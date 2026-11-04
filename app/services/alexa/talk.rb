require "open3"

module Alexa
  # "Falar na Alexa" (widget `announce`, web e app): texto ou voz gravada
  # numa Echo escolhida ou em todas. É o `script.alexa_falar` +
  # `input_select.alexa_destino` + `shell_command.alexa_audio` do HA num
  # lugar só.
  #
  # - Texto: comando `announce` (som de aviso + fala) em cada Echo, pelo
  #   Points::Command de sempre (papel, sombra, histórico de comandos).
  # - Voz: o navegador/app grava (webm, m4a, ogg…); o ffmpeg passa para o MP3
  #   que a Alexa aceita (MPEG-2, 24 kHz, 48 kbps, mono, até 240 s) e a Echo
  #   toca por `<audio src>` no `speak`. A Amazon baixa o arquivo de fora, por
  #   https com certificado válido: o endereço é o `MEDIA_PUBLIC_URL` (o
  #   acesso externo da casa) e o link é curto (o texto do `speak` tem limite),
  #   `/fala/<chave do arquivo>.mp3`, que vale `TTL` e não pede login.
  module Talk
    class Error < StandardError; end

    TTL = 1.day
    MAX_AUDIO = 4.megabytes
    MAX_SECONDS = 60
    AUDIO_TYPES = %r{\Aaudio/(webm|ogg|mp4|m4a|x-m4a|aac|mpeg|mp3|wav|x-wav|3gpp)\b}
    METADATA = "alexa_talk".freeze
    FFMPEG = %w[ffmpeg -hide_banner -loglevel error -y -i pipe:0 -t].freeze
    MP3 = %w[-vn -ac 1 -ar 24000 -b:a 48k -codec:a libmp3lame -f mp3 pipe:1].freeze

    module_function

    # Echos do local (o ponto `speaker` de cada uma), na ordem do nome.
    def speakers(site, ids = nil)
      scope = site.points.joins(:device).where(capability: "speaker", devices: { driver: "alexa" }, disabled: false)
      scope = scope.where(id: ids) if ids.present?
      scope.includes(:device).sort_by { |p| p.device.name.to_s.downcase }
    end

    # Rótulo de cada Echo no seletor: o nome do aparelho (o ponto se chama "Alto-falante").
    def label(point) = point.device.name.presence || point.name

    # Voz gravada dá para tocar? (endereço https de fora + ffmpeg no servidor)
    def audio? = public_base.present? && ffmpeg?

    def public_base
      base = ENV["MEDIA_PUBLIC_URL"].to_s.delete_suffix("/")
      base if base.start_with?("https://")
    end

    def ffmpeg? = @ffmpeg.nil? ? (@ffmpeg = system("ffmpeg", "-version", out: File::NULL, err: File::NULL) == true) : @ffmpeg

    # O pedido da tela: `targets` = "all" ou ids de Echo; texto ou áudio (arquivo enviado). → [Command].
    # `allow` = lambda(ponto) do papel de quem pede (o controller levanta se não pode).
    def call(site, targets:, text: nil, audio: nil, source:, allow: ->(_p) { })
      ids = Array(targets).flat_map { |t| t.to_s.split(",") }.compact_blank
      points = speakers(site, ids.include?("all") ? nil : ids)
      raise Error, I18n.t("dashboards.talk.no_echo") if points.empty?

      points.each { |p| allow.call(p) }
      audio.present? ? play!(points, audio, audio.content_type, source: source) : say!(points, text, source: source)
    end

    # Texto → anúncio em cada Echo. → [Command].
    def say!(points, text, source:)
      clean = text.to_s.delete("<>").gsub("&", " e ").squish
      raise Error, I18n.t("dashboards.talk.empty") if clean.empty?

      Array(points).map { |p| Points::Command.call(p, "announce", clean, source: source) }
    end

    # Voz gravada → MP3 → `speak` com o áudio em cada Echo. → [Command].
    def play!(points, io, content_type, source:)
      raise Error, I18n.t("dashboards.talk.no_audio") unless audio?
      raise Error, I18n.t("dashboards.talk.bad_audio") unless content_type.to_s.match?(AUDIO_TYPES)

      bytes = io.read(MAX_AUDIO + 1).to_s
      raise Error, I18n.t("dashboards.talk.too_big") if bytes.bytesize > MAX_AUDIO
      raise Error, I18n.t("dashboards.talk.bad_audio") if bytes.empty?

      url = store(mp3(bytes))
      Array(points).map { |p| Points::Command.call(p, "speak", %(<audio src="#{url}"/>), source: source) }
    end

    def mp3(bytes)
      out, err, status = Open3.capture3(*FFMPEG, MAX_SECONDS.to_s, *MP3, stdin_data: bytes, binmode: true)
      raise Error, I18n.t("dashboards.talk.bad_audio") unless status.success? && out.bytesize.positive?

      out
    rescue Errno::ENOENT
      raise Error, I18n.t("dashboards.talk.no_audio")
    ensure
      Rails.logger.info("[alexa_talk] ffmpeg: #{err.to_s.truncate(200)}") if err.present?
    end

    # Guarda o MP3 (some depois do TTL) → endereço público curto.
    def store(mp3)
      blob = ActiveStorage::Blob.create_and_upload!(io: StringIO.new(mp3), filename: "fala.mp3", content_type: "audio/mpeg",
                                                    metadata: { METADATA => true })
      ActiveStorage::PurgeJob.set(wait: TTL).perform_later(blob)
      "#{public_base}/fala/#{blob.key}.mp3"
    end

    # Arquivo do link (nil se não é uma fala ou já venceu).
    def blob_for(key)
      blob = ActiveStorage::Blob.find_by(key: key.to_s) or return nil
      blob if blob.metadata[METADATA] && blob.created_at > TTL.ago
    end
  end
end
