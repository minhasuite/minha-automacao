source "https://rubygems.org"

ruby "~> 3.3"

gem "rails", "~> 8.1.4"
# Traduções padrão (validações, datas, números) em pt-BR — padrão da suíte.
gem "rails-i18n", "~> 8.0"
gem "pg", "~> 1.6"
gem "puma", ">= 6.4"
gem "bootsnap", require: false
gem "tzinfo-data", platforms: %i[windows jruby]

# Auth: senha com bcrypt (has_secure_password; o web usa sessão em cookie
# assinado, a API usa ApiToken) e login Google pelo id_token (googleauth).
gem "bcrypt", "~> 3.1"
gem "googleauth", "~> 1.11"

# Multi-tenant (a casa) com require_tenant.
gem "acts_as_tenant", "~> 1.0"

# Fila, cache e Action Cable — Solid* no Postgres, sem Redis.
gem "solid_queue", "~> 1.4"
gem "solid_cache", "~> 1.0"
gem "solid_cable", "~> 3.0"

# API JSON
gem "alba", "~> 3.7"
gem "pagy", "~> 9.0"
gem "rack-cors", "~> 2.0"
gem "rack-attack", "~> 6.7"

# Web: Hotwire + Tailwind (binário standalone, sem Node) + importmap.
gem "propshaft"
gem "importmap-rails"
gem "turbo-rails"
gem "stimulus-rails"
gem "tailwindcss-rails", "~> 4.2"
# Lista Clara da suíte (tokens, .ss-*, Ss::*Component e os controllers ss-*).
# Repo público: sem chave. Traz o view_component.
gem "componentes_ui", git: "https://github.com/minhasuite/componentes-ui.git", tag: "v0.14.1"

# Foto do produto: Active Storage → R2 (variantes com libvips).
gem "image_processing", "~> 2.0"
gem "ruby-vips", "~> 2.0"
gem "active_storage_validations", "~> 1.1"
gem "aws-sdk-s3", require: false

# IA: SDK do Claude (provedor opcional). Gemini e OpenAI vão por Net::HTTP.
gem "anthropic", "~> 1.56"

group :development, :test do
  gem "debug", platforms: %i[mri windows], require: "debug/prelude"
  gem "rspec-rails", "~> 8.0"
  gem "factory_bot_rails", "~> 6.4"
  gem "rubocop", "~> 1.72", require: false
  gem "rubocop-rails", require: false
  gem "rubocop-rspec", require: false
  gem "rubocop-rails-omakase", require: false
  gem "brakeman", require: false
end

group :test do
  gem "webmock", "~> 3.24"
  gem "simplecov", require: false
end

# Automações (F6): expressões sem código arbitrário e textos com objetos limitados.
gem "dentaku", "~> 4.1"

# Driver mqtt (F8): Mosquitto local e zigbee2mqtt.
gem "mqtt", "0.6.0"
gem "liquid", "~> 5.14"

# Integrações (F8c): QR code do login da Tuya (SVG no servidor).
gem "rqrcode", "~> 3.1"
# Web Push (VAPID) para a PWA: canal "push" sem o app nativo (Lote 1).
gem "web-push", "~> 3.1"
