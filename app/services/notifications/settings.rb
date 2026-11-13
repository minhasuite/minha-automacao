module Notifications
  # Grava as preferências (Configurações → Notificações e a API): as da pessoa
  # sempre; as da casa (silêncio dos canais da casa e janela de juntar) só
  # para administradores. Valores fora do formato voltam ao padrão.
  module Settings
    module_function

    def update(user, params)
      params = params.to_h.stringify_keys
      prefs = Notifications.user_prefs(user)
      prefs["quiet"] = window(params, "quiet", prefs["quiet"])
      prefs["digest"] = { "enabled" => bool(params["digest_enabled"]), "at" => time(params["digest_at"], prefs.dig("digest", "at")) }
      prefs["mute_hours"] = params["mute_hours"].to_i.presence_in(MUTE_HOURS) || prefs["mute_hours"]
      Notifications.save_user!(user, prefs)
      return unless user.admin? && params.key?("house_quiet_enabled")

      house = Notifications.house_prefs(user.tenant)
      house["quiet"] = window(params, "house_quiet", house["quiet"])
      house["merge_s"] = params["merge_s"].to_i.presence_in(MERGE_CHOICES) || 0 if params.key?("merge_s")
      Notifications.save_house!(user.tenant, house)
    end

    def window(params, prefix, current)
      { "enabled" => bool(params["#{prefix}_enabled"]), "from" => time(params["#{prefix}_from"], current["from"]),
        "to" => time(params["#{prefix}_to"], current["to"]) }
    end

    def bool(v) = ActiveModel::Type::Boolean.new.cast(v) == true
    def time(v, fallback) = TIME.match?(v.to_s[0, 5]) ? v.to_s[0, 5] : fallback

    # O que a tela e a API mostram.
    def show(user)
      prefs = Notifications.user_prefs(user)
      out = { "quiet" => prefs["quiet"], "digest" => prefs["digest"], "mute_hours" => prefs["mute_hours"].to_i,
              "mutes" => Notifications.mute_list(user).map { |m| m.merge("until" => m["until"].iso8601) } }
      out["house"] = Notifications.house_prefs(user.tenant).slice("quiet", "merge_s") if user.admin?
      out
    end
  end
end
