require "net/http"

# Há internet? (voz-offline) Um HEAD curto num endereço fixo de conectividade
# (`INTERNET_CHECK_URL`, padrão o generate_204 do Google), com a resposta
# guardada por TTL segundos no processo: o Assist pergunta antes de mandar
# voz ou texto para um provedor da nuvem, e a web e o app mostram "modo
# offline". `MA_OFFLINE=1` força o modo offline (testar a casa sem nuvem).
# Nada aqui vem do usuário: o endereço é da instalação (env), não da tela.
module Internet
  URL = ENV.fetch("INTERNET_CHECK_URL", "https://connectivitycheck.gstatic.com/generate_204")
  TTL = 60
  TIMEOUT = 2
  @lock = Mutex.new
  @cache = nil

  module_function

  def online?
    return false if ENV["MA_OFFLINE"] == "1"

    lock.synchronize do
      @cache = nil if @cache && Process.clock_gettime(Process::CLOCK_MONOTONIC) - @cache[:at] > TTL
      (@cache ||= { at: Process.clock_gettime(Process::CLOCK_MONOTONIC), value: probe })[:value]
    end
  end

  def offline? = !online?

  # Esquece a última resposta (depois de mudar a rede, e nos specs).
  def reset! = lock.synchronize { @cache = nil }

  # Qualquer resposta HTTP (até 4xx) = a rede chega lá; erro de rede ou tempo esgotado = sem internet.
  def probe
    uri = URI(URL)
    Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https", open_timeout: TIMEOUT, read_timeout: TIMEOUT) do |http|
      http.head(uri.request_uri).code.to_i < 500
    end
  rescue StandardError, Timeout::Error => e
    Rails.logger.info("[internet] sem internet: #{e.class}")
    false
  end

  def lock = @lock
end
