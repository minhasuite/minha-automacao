module MediaSources
  # Gravações das câmeras (ondaC2, C10) como fonte de mídia: câmera → dia →
  # trechos; toca no navegador, no app ou numa TV da casa.
  class Recordings < Source
    describe key: "recordings", title: "Gravações das câmeras", icon: "video-camera",
             description: "Trechos gravados pelas câmeras, por dia, para ver aqui ou mandar para a TV."
    texts en: { title: "Camera recordings", description: "Clips recorded by the cameras, by day, to watch here or send to the TV.",
                triggers: { continuous: "Continuous", event: "Motion", manual: "On demand" } },
          es: { title: "Grabaciones de las cámaras", description: "Fragmentos grabados por las cámaras, por día, para ver aquí o enviar a la TV.",
                triggers: { continuous: "Continua", event: "Movimiento", manual: "Al momento" } },
          "pt-BR" => { triggers: { continuous: "Contínua", event: "Movimento", manual: "Na hora" } }

    class << self
      def root(site_id) = ::Recordings.root(site_id)
      def cameras(site) = site.points.includes(:device).where(id: CameraRecording.where(site: site).select(:point_id)).order(:name)
      def available?(site) = CameraRecording.exists?(site_id: site.id)

      def browse(site, path, query: nil) # rubocop:disable Lint/UnusedMethodArgument
        point_id, day = path.to_s.split("/", 2)
        return page(title, nil, cameras(site).map { |p| item(id: p.id, title: p.device.name, kind: "folder", subtitle: p.name) }) if point_id.blank?

        point = site.points.find(point_id)
        if day.blank?
          items = ::Recordings.days(point).map { |d| item(id: "#{point.id}/#{d.iso8601}", title: I18n.l(d, format: :long), kind: "folder") }
          return page(point.device.name, "", items)
        end

        items = ::Recordings.of_day(point, Date.iso8601(day)).map do |r|
          item(id: r.id, title: I18n.l(r.started_at, format: :short), kind: "video",
               subtitle: "#{text("triggers.#{r.trigger}")} · #{format("%d:%02d", r.duration_s / 60, r.duration_s % 60)}")
        end
        page(I18n.l(Date.iso8601(day), format: :long), point.id, items)
      rescue Date::Error
        raise ArgumentError, "dia inválido"
      end

      def recording(site, id) = CameraRecording.where(site: site).find(id)
      def media_url(site, id) = MediaSources.file_url(site, "rec", recording(site, id).file)
      def preview_url(site, id) = MediaSources.file_url(site, "rec", recording(site, id).file, absolute: false)
    end
  end
end
