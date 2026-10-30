module AppsHelper
  # Estado do app para a tela: [rótulo, tom do badge].
  def app_state(status)
    return [ "Não instalado", nil ] unless status&.dig("installed") || status&.dig("busy")
    return [ status["busy"], "accent" ] if status["busy"]
    return [ "Com erro", "danger" ] if status["error"] || status["health"] == "unhealthy" || %w[restarting dead].include?(status["state"])
    return [ "Rodando", "success" ] if status["state"] == "running"

    [ "Parado", "warn" ]
  end

  def app_update?(app, status) = !app.system? && status&.dig("installed") && status["version"] != app.version
end
