# CORS só importa para cliente de navegador. Quem consome a API é o app
# nativo, que não manda Origin — então o padrão é não liberar nada. Para um
# cliente web, liste as origens em API_CORS_ORIGINS (vírgula).
origins_list = ENV.fetch("API_CORS_ORIGINS", "").split(",").map(&:strip).reject(&:blank?)

if origins_list.any?
  Rails.application.config.middleware.insert_before 0, Rack::Cors do
    allow do
      origins(*origins_list)
      resource "/api/*", headers: :any, methods: %i[get post patch put delete options], credentials: false
    end
  end
end
