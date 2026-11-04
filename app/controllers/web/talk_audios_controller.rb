module Web
  # O MP3 que a Echo baixa para tocar a voz gravada (Alexa::Talk): a Amazon
  # não tem sessão; o link é a chave aleatória do arquivo e vale 1 dia.
  class TalkAudiosController < ActionController::Base # rubocop:disable Rails/ApplicationController
    def show
      blob = Alexa::Talk.blob_for(params[:key]) or return head(:not_found)

      response.headers["Cache-Control"] = "private, max-age=3600"
      send_data blob.download, type: "audio/mpeg", disposition: "inline", filename: "fala.mp3"
    end
  end
end
