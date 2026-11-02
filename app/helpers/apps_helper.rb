module AppsHelper
  # Estado do app para a tela: [rótulo, tom do badge].
  def app_state(status)
    return [ t("apps.state.not_installed"), nil ] unless status&.dig("installed") || status&.dig("busy")
    return [ status["busy"], "accent" ] if status["busy"]
    return [ t("apps.state.error"), "danger" ] if status["error"] || status["health"] == "unhealthy" || %w[restarting dead].include?(status["state"])
    return [ t("apps.state.running"), "success" ] if status["state"] == "running"

    [ t("apps.state.stopped"), "warn" ]
  end

  def app_update?(app, status) = !app.system? && status&.dig("installed") && status["version"] != app.version
end
