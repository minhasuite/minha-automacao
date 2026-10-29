# frozen_string_literal: true

# O que cada requisição conta ao meulog, além do erro.
#
# Três coisas, e cada uma responde uma pergunta que o painel não respondia:
#
# - **medição** (`MeuLog.measure`): quanto a ação levou. É o que enche a aba
#   Desempenho, com P95 por operação. O nome é `controller#action`; o meulog tem
#   teto de nomes por projeto e manda o excedente para um balaio, então
#   controller novo não estoura nada.
# - **contexto do erro** (`Rails.error.set_context`): quem estava na ação e em
#   que plano. Vale para os DOIS destinos — a issue no GitHub e o meulog — porque
#   os dois leem o mesmo `Rails.error`. Sem isto, erro de produção chegava sem
#   dono e sem plano, e "é bug de quem paga?" ficava sem resposta.
# - **evento de uso** (`MeuLog.track`): o que o cliente pede ao servidor. Só onde
#   `meulog_uso_por_requisicao?` é verdadeiro — hoje a API.
#
# O web fica FORA do evento de uso de propósito: a navegação do navegador já é
# reportada pelo `meulog.js` no projeto "web", e a mesma visita contada em dois
# projetos é duas contagens que discordam.
#
# Nada aqui pode custar a requisição: `MeuLog.measure` não engole a exceção do
# bloco (quem chamou precisa saber que falhou), e o resto é best-effort com o
# erro apenas logado.
module MeuLogInstrumented
  extend ActiveSupport::Concern

  included do
    before_action :meulog_contexto_do_erro
    around_action :meulog_mede_a_acao
  end

  private

  def meulog_operacao = "#{controller_name}##{action_name}"

  # Sobrescreva com `true` onde a requisição em si é informação.
  def meulog_uso_por_requisicao? = false

  def meulog_usuario
    return @current_api_user if defined?(@current_api_user)

    nil
  rescue StandardError
    nil # Devise sem Warden, token inválido: contexto é enfeite, não pode quebrar
  end

  def meulog_contexto_do_erro
    usuario = meulog_usuario
    Rails.error.set_context(rota: meulog_operacao, usuario: usuario&.id,
                            empresa: usuario&.tenant&.plan)
  rescue StandardError => e
    Rails.logger.warn("[meulog] contexto não setado: #{e.class}: #{e.message}")
  end

  def meulog_mede_a_acao(&bloco)
    return yield unless MeuLog.configured?

    MeuLog.measure(meulog_operacao, &bloco)
  ensure
    meulog_conta_uso
  end

  def meulog_conta_uso
    return unless meulog_uso_por_requisicao? && MeuLog.configured?

    usuario = meulog_usuario
    MeuLog.track(meulog_operacao,
               user: usuario&.id&.to_s, customer: usuario&.tenant&.plan&.to_s,
               metodo: request.request_method, status: response&.status)
  rescue StandardError => e
    Rails.logger.warn("[meulog] uso não contado: #{e.class}: #{e.message}")
  end
end
