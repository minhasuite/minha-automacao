require "net/http"
require "json"

# Integrador (docs/PROPOSTA-integrador.md, 24/11/2026): o integrador instala e mantém o MA nos clientes e acompanha
# todos de uma central. Dois papéis, no mesmo código:
#
# - **Instalação** (`INTEGRATOR_URL` + `INTEGRATOR_TOKEN`): a cada 5 min o `IntegratorReportJob` manda o resumo
#   (`Integrator::Report`) para a central e guarda a resposta (versão liberada pela central) em
#   `storage/integrator.json`. Sem as duas variáveis, desligado.
# - **Central** (`INTEGRATOR_HUB=1`): recebe os resumos em `POST /api/v1/integrador/resumo` (token de cada
#   instalação), mostra a lista em `/integrador` e avisa o integrador (`Integrator::Watch`).
#
# O resumo leva só contagens e situações: nada de imagem, nome de pessoa, nome de aparelho, localização ou conteúdo
# de aviso (LGPD). A central sabe SE a casa está bem, não O QUE acontece nela.
module Integrator
  class Error < StandardError; end

  SEND_EVERY = 5.minutes
  TIMEOUT = 10

  module_function

  def url = ENV["INTEGRATOR_URL"].presence
  def token = ENV["INTEGRATOR_TOKEN"].presence
  def reporting? = url.present? && token.present?
  def hub? = ENV["INTEGRATOR_HUB"] == "1"

  def state_path = Rails.root.join("storage/integrator.json")

  def state
    File.exist?(state_path) ? JSON.parse(File.read(state_path)) : {}
  rescue JSON::ParserError
    {}
  end

  def save_state!(patch)
    FileUtils.mkdir_p(File.dirname(state_path))
    File.write(state_path, JSON.generate(state.merge(patch)))
  end

  # Versão mais nova que a central libera (freio de atualização); nil = sem limite.
  def max_version = state["max_version"].presence

  # Manda o resumo; → a resposta da central (Hash). Falha fica no estado e o próximo envio tenta de novo.
  def send_report!(payload = Report.build, now: Time.current)
    uri = URI.join(url, "/api/v1/integrador/resumo")
    req = Net::HTTP::Post.new(uri, "Content-Type" => "application/json", "Authorization" => "Bearer #{token}")
    req.body = JSON.generate(payload)
    res = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https", open_timeout: TIMEOUT, read_timeout: TIMEOUT) { |h| h.request(req) }
    raise Error, "a central respondeu #{res.code}" unless res.is_a?(Net::HTTPSuccess)

    body = JSON.parse(res.body.presence || "{}")
    save_state!("sent_at" => now.iso8601, "error" => nil, "max_version" => body["max_version"])
    body
  rescue SystemCallError, SocketError, Timeout::Error, IOError, OpenSSL::SSL::SSLError, JSON::ParserError, Error => e
    save_state!("error" => e.message.truncate(200), "error_at" => now.iso8601)
    raise Error, e.message
  end
end
