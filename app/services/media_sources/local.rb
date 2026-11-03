module MediaSources
  # Pasta de mídia do local (o /media do HA): `MEDIA_DIR/<id do local>`
  # (padrão storage/media). Pastas, envio de arquivos e apagar pela tela.
  class Local < Source
    MAX_UPLOAD = 1.gigabyte
    NAME = %r{\A[^/\\\0]{1,120}\z}

    describe key: "local", title: "Arquivos de mídia", icon: "music-note",
             description: "Músicas, vídeos e fotos enviados para o servidor, em pastas."
    texts en: { title: "Media files", description: "Music, videos and photos uploaded to the server, in folders.",
                bad_name: "Invalid name.", too_big: "File too large (up to 1 GB).", not_media: "Upload audio, video or an image." },
          es: { title: "Archivos multimedia", description: "Música, videos y fotos subidos al servidor, en carpetas.",
                bad_name: "Nombre inválido.", too_big: "Archivo demasiado grande (hasta 1 GB).", not_media: "Sube audio, video o una imagen." },
          "pt-BR" => { bad_name: "Nome inválido.", too_big: "Arquivo grande demais (até 1 GB).", not_media: "Envie áudio, vídeo ou imagem." }

    class << self
      def uploads? = true
      def root(site_id) = Pathname(ENV["MEDIA_DIR"].presence || Rails.root.join("storage/media")).join(site_id.to_s)
      def dir(site, path) = MediaSources.safe_join(root(site.id), path.to_s) || raise(ArgumentError, text(:bad_name))

      def browse(site, path, query: nil) # rubocop:disable Lint/UnusedMethodArgument
        base = dir(site, path)
        entries = base.directory? ? base.children.reject { |c| c.basename.to_s.start_with?(".") } : []
        dirs, files = entries.partition(&:directory?)
        items = dirs.sort.map { |d| item(id: rel(path, d), title: d.basename.to_s, kind: "folder") } +
                files.sort.filter_map do |f|
                  kind = MediaSources.kind_of(f)
                  next if kind == "other"

                  item(id: rel(path, f), title: f.basename.to_s, kind: kind, subtitle: ActiveSupport::NumberHelper.number_to_human_size(f.size),
                       thumb: (MediaSources.file_url(site, "local", rel(path, f), absolute: false) if kind == "image"))
                end
        page(path.present? ? File.basename(path) : title, (File.dirname(path).delete_prefix(".") if path.present?), items)
      end

      def rel(path, child) = [ path.presence, child.basename.to_s ].compact.join("/")
      def media_url(site, id) = MediaSources.file_url(site, "local", id)
      def preview_url(site, id) = MediaSources.file_url(site, "local", id, absolute: false)

      def valid_name?(name) = name.to_s.match?(NAME) && !name.to_s.start_with?(".")

      def mkdir(site, path, name)
        raise ArgumentError, text(:bad_name) unless valid_name?(name.to_s.strip)

        FileUtils.mkdir_p(dir(site, path).join(name.strip))
      end

      def upload(site, path, file)
        name = File.basename(file.original_filename.to_s)
        raise ArgumentError, text(:bad_name) unless valid_name?(name)
        raise ArgumentError, text(:not_media) if MediaSources.kind_of(name) == "other"
        raise ArgumentError, text(:too_big) if file.size > MAX_UPLOAD

        target = dir(site, path)
        FileUtils.mkdir_p(target)
        IO.copy_stream(file.respond_to?(:tempfile) ? file.tempfile : file.path, target.join(name))
      end

      def delete(site, path)
        raise ArgumentError, text(:bad_name) if path.blank?

        FileUtils.rm_rf(dir(site, path))
      end
    end
  end
end
