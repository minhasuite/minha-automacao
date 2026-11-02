# Navegador inscrito no Web Push (PWA instalada ou navegador do computador):
# um transporte do canal "push" (Push::Browser), ao lado do FCM do app
# nativo. Não é tenant-scoped, como DeviceToken: o push roda em background e
# chega pelo usuário. Tela em Configurações → Minha conta → Meus aparelhos.
class PushSubscription < ApplicationRecord
  belongs_to :user

  validates :endpoint, presence: true, uniqueness: true, format: { with: %r{\Ahttps://\S+\z}, message: :https }
  validates :p256dh_key, :auth_key, presence: true

  scope :ordered, -> { order(created_at: :desc) }

  # Nome padrão pelo navegador ("Chrome no Android").
  def self.guess_name(agent)
    agent = agent.to_s
    browser = { "Edg/" => "Edge", "Firefox/" => "Firefox", "SamsungBrowser" => "Samsung Internet", "Chrome/" => "Chrome", "Safari/" => "Safari" }
              .find { |k, _| agent.include?(k) }&.last || "Navegador"
    os = { "Android" => "Android", "iPhone" => "iPhone", "iPad" => "iPad", "Windows" => "Windows", "Mac OS" => "Mac", "Linux" => "Linux" }
         .find { |k, _| agent.include?(k) }&.last
    [ browser, os ].compact.join(" no ")
  end
end
