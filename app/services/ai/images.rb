module Ai
  # Imagens da ação "Pedir à IA": quadro das câmeras agora (go2rtc), imagem
  # por URL (https pelo SafeHttp) ou anexo já guardado no sistema (caminho
  # /rails/active_storage/..., como o quadro de um aviso). Uma que falha não
  # derruba as outras: vira nota no trace.
  module Images
    MAX = 4
    MAX_BYTES = 5.megabytes
    BLOB = %r{\A/rails/active_storage/blobs/(?:redirect/|proxy/)?([^/]+)/}

    module_function

    # → [[{media_type:, data:}], ["nota", ...]]
    def collect(ctx, camera_ids, urls_text)
      images = []
      notes = []
      Array(camera_ids).each do |id|
        point = ctx.point(id) or next notes << "câmera removida"
        images << encode("image/jpeg", Drivers::Go2rtc.snapshot(point))
      rescue Drivers::Go2rtc::Error => e
        notes << "#{point.name}: #{e.message}"
      end
      urls_text.to_s.lines.map(&:strip).compact_blank.each do |url|
        images << fetch(url)
      rescue SafeHttp::Error, ArgumentError, ActiveStorage::FileNotFoundError => e
        notes << "imagem #{url.truncate(40)}: #{e.message.truncate(80)}"
      end
      raise ArgumentError, "no máximo #{MAX} imagens." if images.size > MAX

      [ images, notes ]
    end

    def fetch(url)
      if (m = BLOB.match(url))
        blob = ActiveStorage::Blob.find_signed(m[1]) or raise ArgumentError, "anexo não encontrado"
        return image(blob.content_type, blob.download)
      end

      res = SafeHttp.get(url, timeout: 15)
      raise ArgumentError, "respondeu #{res.status}" if res.status >= 400

      image(Array(res.headers["content-type"]).first.to_s.split(";").first, res.body)
    end

    def image(type, bytes)
      raise ArgumentError, "não é imagem" unless type.to_s.start_with?("image/")
      raise ArgumentError, "imagem grande demais" if bytes.bytesize > MAX_BYTES

      encode(type, bytes)
    end

    def encode(type, bytes) = { media_type: type, data: Base64.strict_encode64(bytes) }
  end
end
