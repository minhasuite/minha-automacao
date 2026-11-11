module Dashboards
  # Ações em lote do painel (ideia 12): "Apagar tudo do cômodo", "Fechar tudo".
  # A ação `command_query` (`Dashboards::Actions::CommandQuery`) diz a consulta
  # e o comando; aqui ficam os alvos e o envio. Regras:
  #
  # - a consulta e o comando vêm SEMPRE da definição publicada do widget (o
  #   pedido só diz qual lugar do widget foi tocado), nunca do cliente;
  # - ponto que só lê ou não aceita o comando fica de fora;
  # - papel x risco por ponto (`SiteMembership.allowed?`); o que o papel não
  #   comanda é pulado e contado;
  # - ponto crítico nunca vai em lote (portão, sirene: um por vez, na tela dele);
  # - cada ponto vira um `Command` (a trilha) por `Points::Command`.
  module Batch
    MAX = 100
    Result = Struct.new(:sent, :skipped, :failed, keyword_init: true) do
      def to_h = { "sent" => sent, "skipped" => skipped, "failed" => failed }
    end

    module_function

    # Pontos que recebem o comando (a área do widget já em `_scope`).
    def targets(r, a)
      q = Points::Query.parse(a["query"]).merge(a["_scope"].to_h)
      r.query(q).select { |p| writable?(p) && Points::Command.commands_for(p).include?(a["command"].to_s) && p.risk != "critical" }.first(MAX)
    rescue ArgumentError
      []
    end

    def writable?(p) = p.writable && !p.disabled && !p.device.disabled && Drivers.supported?(p.device)
    def allowed?(role, p) = SiteMembership.allowed?(role, :command, risk: p.risk)

    # Manda o comando aos alvos que o papel comanda. → Result.
    def run(r, a, source:, user: Current.user)
      sent = skipped = 0
      failed = []
      targets(r, a).each do |p|
        next skipped += 1 unless allowed?(r.role, p)

        c = Points::Command.call(p, a["command"], a["value"], source: source, user: user)
        c.status == "failed" ? failed << "#{p.name}: #{c.error}" : sent += 1
      rescue Points::Command::Error => e
        failed << "#{p.name}: #{e.message}"
      end
      Result.new(sent: sent, skipped: skipped, failed: failed)
    end

    # Ação em lote de um lugar do widget (já resolvido para o papel), com a área do widget.
    def action_for(w, slot, site:)
      a = Actions.slot(w, slot, site: site)
      a.merge("_scope" => Actions.scope(w)) if a.is_a?(Hash) && a["action"] == Actions::CommandQuery.key
    end

    def message(result)
      parts = [ I18n.t("dashboards.batch.sent", count: result.sent) ]
      parts << I18n.t("dashboards.batch.skipped", count: result.skipped) if result.skipped.positive?
      parts << I18n.t("dashboards.batch.failed", count: result.failed.size) if result.failed.any?
      parts.join(" · ")
    end
  end
end
