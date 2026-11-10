# Confiabilidade: sem pausas de verdade no spec (ritmo da Alexa e nova
# tentativa na hora dos clientes de nuvem); o spec próprio liga quando precisa.
RSpec.configure do |config|
  config.before do
    Alexa::Throttle.gap = 0
    Alexa::Throttle.reset!
    Transient.inline_pause = 0
  end
end
