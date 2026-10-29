require_relative "boot"

require "rails"
# Pick the frameworks you want:
require "active_model/railtie"
require "active_job/railtie"
require "active_record/railtie"
require "active_storage/engine"
require "action_controller/railtie"
require "action_mailer/railtie"
# require "action_mailbox/engine"
# require "action_text/engine"
require "action_view/railtie"
# require "action_cable/engine"
# require "rails/test_unit/railtie"

# Require the gems listed in Gemfile, including any gems
# you've limited to :test, :development, or :production.
Bundler.require(*Rails.groups)

module MinhaAutomacao
  class Application < Rails::Application
    # Initialize configuration defaults for originally generated Rails version.
    config.load_defaults 8.1

    # Please, add to the `ignore` list any other `lib` subdirectories that do
    # not contain `.rb` files, or that should not be reloaded or eager loaded.
    # Common ones are `templates`, `generators`, or `middleware`, for example.
    config.autoload_lib(ignore: %w[assets tasks])

    # Configuration for the application, engines, and railties goes here.
    #
    # These settings can be overridden in specific environments using the files
    # in config/environments, which are processed later.
    #
    # Padrão da suíte: pt-BR e America/Sao_Paulo ("hoje" e "vence em 3 dias"
    # são datas do Brasil, não do servidor em UTC). O banco grava em UTC.
    config.time_zone = "America/Sao_Paulo"
    config.i18n.default_locale = :"pt-BR"
    config.i18n.available_locales = [ :"pt-BR", :en ]
    config.i18n.fallbacks = [ :en ]

    # UUID em toda tabela (inclusive as do Active Storage).
    config.generators.orm :active_record, primary_key_type: :uuid

    # Monolito: web (Hotwire, sessão em cookie) e API /api/v1 (ApiToken, sem
    # cookie) no mesmo processo. Api::V1::BaseController herda de
    # ActionController::API.
  end
end
