# Falha passageira que pode ser repetida com segurança (docs/confiabilidade.md).
#
# Só repete quando é CERTO que nada chegou ao aparelho ou ao serviço:
#   :connect  a conexão nem se abriu (Net::OpenTimeout, recusa, sem rota,
#             DNS, aperto de mão TLS) ou o código marcou o erro com NotSent;
#   :busy     o serviço recusou explicitamente sem efeito (HTTP 429/502/503/504,
#             erro com o módulo Busy), honrando o Retry-After.
# Leitura que estourou depois do envio (Net::ReadTimeout), conexão que caiu no
# meio, erro desconhecido e recusa do próprio aparelho NUNCA repetem.
# Ponto crítico (portão, sirene, fechadura: `strict: true`) só repete :connect.
#
# Olha a cadeia de `cause`: os clientes embrulham o erro de rede no deles
# ("Sem conexão com a Tuya (OpenTimeout)") dentro do rescue, e o Ruby guarda o
# original em `cause`.
module Transient
  # Marca para erro levantado antes de qualquer byte do pedido sair (ex.:
  # Tuya::Connection::ConnectError).
  module NotSent; end

  # Marca para recusa explícita do serviço: `status` (HTTP) e `retry_after` (s).
  module Busy
    attr_reader :status, :retry_after

    def initialize(message = nil, status: nil, retry_after: nil)
      @status = status.to_i
      @retry_after = retry_after
      super(message)
    end
  end

  CONNECT_ERRORS = [ Net::OpenTimeout, Errno::ECONNREFUSED, Errno::EHOSTUNREACH, Errno::ENETUNREACH,
                     Errno::EHOSTDOWN, Errno::ENETDOWN, SocketError ].freeze
  STATUSES = [ 429, 502, 503, 504 ].freeze
  # Espera antes de cada nova tentativa (a 1ª falha espera 5 s, a 2ª 30 s, a 3ª 2 min).
  WAITS = [ 5, 30, 120 ].freeze
  MAX_RETRY_AFTER = 300
  MAX_DEPTH = 4

  module_function

  # :connect, :busy ou nil (não repetir).
  def kind(error)
    e = error
    MAX_DEPTH.times do
      return nil if e.nil?
      return :connect if connect?(e)
      return :busy if e.is_a?(Busy) && STATUSES.include?(e.status)

      e = e.cause
    end
    nil
  end

  def retryable?(error, strict: false)
    k = kind(error)
    k == :connect || (k == :busy && !strict)
  end

  def connect?(e)
    return true if e.is_a?(NotSent) || CONNECT_ERRORS.any? { |k| e.is_a?(k) }

    # Só o aperto de mão (SSL_connect); erro de leitura TLS depois do envio não conta.
    e.is_a?(OpenSSL::SSL::SSLError) && e.message.include?("SSL_connect")
  end

  # Segundos até a próxima tentativa depois da falha `attempt` (1, 2, 3...) ou
  # nil quando acabaram. O Retry-After do serviço vale mais que a tabela.
  def wait(attempt, error = nil)
    base = WAITS[attempt - 1] or return nil
    after = retry_after(error)
    after ? after.clamp(1, MAX_RETRY_AFTER) : base
  end

  def retry_after(error)
    e = error
    MAX_DEPTH.times do
      break if e.nil?
      return e.retry_after.to_f.ceil if e.is_a?(Busy) && e.retry_after.to_f.positive?

      e = e.cause
    end
    nil
  end

  # Retry-After do HTTP: segundos ou data.
  def parse_retry_after(value)
    return nil if value.blank?
    return value.to_i if value.to_s.match?(/\A\d+\z/)

    (Time.httpdate(value.to_s) - Time.now).ceil.clamp(0, MAX_RETRY_AFTER)
  rescue ArgumentError
    nil
  end

  # Repete na hora (pausa curta) só quando a conexão nem se abriu. Para os
  # clientes de nuvem (Tuya, Xiaomi), em que o pedido seguinte é igual.
  def with_retry(tries: 2, pause: inline_pause)
    attempt = 0
    begin
      attempt += 1
      yield
    rescue StandardError => e
      raise unless attempt < tries && kind(e) == :connect

      sleep(pause) if pause.positive?
      retry
    end
  end

  # Pausa entre as tentativas na hora (o spec zera).
  mattr_accessor :inline_pause, default: 1.0
end
