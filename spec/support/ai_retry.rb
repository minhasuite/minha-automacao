# A nova tentativa da IA (Ai::Request) espera entre as chamadas: nos specs, sem esperar.
RSpec.configure do |config|
  config.before { Ai::Request.sleeper = ->(_seconds) { } }
end
