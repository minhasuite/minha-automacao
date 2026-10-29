class Rack::Attack
  Rack::Attack.cache.store = Rails.cache

  throttle("logins/ip", limit: 5, period: 1.minute) do |req|
    req.ip if req.path == "/api/v1/auth/login" && req.post?
  end

  throttle("signup/ip", limit: 5, period: 1.minute) do |req|
    req.ip if req.path == "/api/v1/auth/signup" && req.post?
  end

  throttle("google/ip", limit: 10, period: 1.minute) do |req|
    req.ip if req.path == "/api/v1/auth/google" && req.post?
  end

  # Entrar numa empresa é adivinhar um código: teto apertado.
  throttle("company_join/ip", limit: 5, period: 5.minutes) do |req|
    req.ip if req.path == "/api/v1/company/join" && req.post?
  end

  # Esqueci a senha: por IP (o controller ainda limita 3/h por e-mail).
  throttle("password_forgot/ip", limit: 5, period: 15.minutes) do |req|
    req.ip if req.path == "/api/v1/auth/password/forgot" && req.post?
  end

  throttle("password_reset/ip", limit: 10, period: 15.minutes) do |req|
    req.ip if req.path == "/api/v1/auth/password/reset" && req.post?
  end

  throttle("api/token", limit: 300, period: 1.minute) do |req|
    req.env["HTTP_AUTHORIZATION"] if req.path.start_with?("/api/v1/") && req.env["HTTP_AUTHORIZATION"].present?
  end

  self.throttled_responder = lambda do |_request|
    body = { error: { code: "rate_limited", message: "Muitas requisições, tente de novo em instantes." } }
    [ 429, { "Content-Type" => "application/json" }, [ body.to_json ] ]
  end
end
