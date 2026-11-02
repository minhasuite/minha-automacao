module Weather
  module Providers
    # Interface de um provedor de clima. Subclasse = plugin: descreve-se e
    # implementa `fetch(lat:, lon:, zone:, api_key:)` devolvendo o formato
    # comum de `Weather`. Rede só pelo `SafeHttp`; erro do serviço = Weather::Error.
    class Base
      extend PluginTexts
      translates :label

      class << self
        attr_reader :key, :needs_key

        def describe(key:, label:, needs_key: false)
          @key = key
          @label = label
          @needs_key = needs_key
        end

        def fetch(lat:, lon:, zone:, api_key: nil) = raise(NotImplementedError)
      end
    end
  end
end
