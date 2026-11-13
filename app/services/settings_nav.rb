# Itens de Configurações (subnavegação `web/settings/_frame` e a busca, `Search::SettingsSource`):
# a mesma lista e a mesma regra de quem vê. Item novo = uma linha aqui.
module SettingsNav
  module_function

  # [chave, rótulo (i18n), rota, ícone, quem vê]
  ITEMS = [
    [ :sites, "nav.sites", :sites_path, "home", ->(u) { !u.reader? } ],
    [ :dashboards, "settings.nav.dashboards", :settings_dashboards_path, "view-boards", ->(u) { !u.reader? } ],
    [ :people, "settings.nav.people", :people_path, "users", ->(u) { u.admin? } ],
    [ :api_keys, "settings.nav.api_keys", :api_keys_path, "link", ->(u) { u.owner? } ],
    [ :apps, "settings.nav.apps", :apps_path, "cube", ->(u) { u.owner? } ],
    [ :ai, "settings.nav.ai", :settings_ai_path, "sparkles", ->(u) { u.admin? } ],
    [ :health, "settings.nav.health", :settings_health_path, "shield-check", ->(u) { u.admin? } ],
    [ :hardware, "hardware.nav", :settings_hardware_path, "chip", ->(u) { u.owner? } ],
    [ :backups, "backup_restore.nav", :settings_backups_path, "download", ->(u) { Backups::Restore.allowed?(u) } ],
    [ :logs, "logs.nav", :settings_logs_path, "document-text", ->(u) { SystemLog.visible_to?(u) } ],
    [ :queue, "queue.nav", :settings_queue_path, "clock", ->(u) { QueueMonitor.visible_to?(u) } ],
    [ :labels, "settings.nav.labels", :tags_path, "tag", ->(u) { u.admin? } ],
    [ :system, "settings.nav.system", :settings_system_path, "cog", ->(u) { !u.reader? } ],
    [ :remote, "settings.nav.remote", :settings_remote_path, "globe", ->(u) { u.admin? } ],
    [ :account, "settings.nav.account", :settings_account_path, "user-group", ->(_u) { true } ],
    [ :security, "security.nav", :settings_security_path, "shield-check", ->(_u) { true } ],
    [ :appearance, "appearance.nav", :settings_appearance_path, "color-swatch", ->(_u) { true } ],
    [ :push, "settings.nav.push", :push_subscriptions_path, "bell", ->(_u) { true } ]
  ].freeze

  # [{key:, label:, path:, icon:}] do que a pessoa vê.
  def items(user)
    ITEMS.select { |*, can| can.call(user) }.map { |key, label, route, ico| { key: key, label: I18n.t(label), path: Rails.application.routes.url_helpers.public_send(route), icon: ico } }
  end
end
