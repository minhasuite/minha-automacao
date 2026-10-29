class ApplicationMailer < ActionMailer::Base
  default from: -> { ENV.fetch("MAIL_FROM", "Minha Automação <nao-responda@minhasuite.com>") }

  # E-mail só sai com SMTP configurado (SMTP_ADDRESS). Sem ele, quem chama
  # registra no log e segue (ex.: "esqueci a senha" continua 200).
  def self.deliverable? = Rails.env.test? || ENV["SMTP_ADDRESS"].present?
  layout "mailer"
end
