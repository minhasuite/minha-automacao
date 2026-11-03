module Web
  # Arquivo de mídia por link assinado (ondaC2): o player da rede (TV, caixa,
  # Chromecast) e o go2rtc não têm sessão; o link (`MediaSources.file_url`)
  # vale algumas horas e só abre arquivo da pasta de mídia ou das gravações
  # do local que assinou. Com Range (o player pula no vídeo).
  class MediaFilesController < ActionController::Base # rubocop:disable Rails/ApplicationController
    def show
      path = MediaSources.file_for(params[:t])
      return head(:not_found) unless path&.file?

      status, headers, body = Rack::Files.new(nil).serving(request, path.to_s)
      self.status = status
      response.headers.merge!(headers)
      response.headers["Cache-Control"] = "private, max-age=3600"
      self.response_body = body
    end
  end
end
