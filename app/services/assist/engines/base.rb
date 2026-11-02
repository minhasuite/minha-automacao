module Assist
  module Engines
    class Base
      extend PluginTexts
      translates :label, :hint

      class << self
        attr_reader :key, :kinds, :fields

        def describe(key:, label:, kinds:, fields: [], hint: nil)
          @key = key
          @label = label
          @kinds = kinds.map(&:to_sym)
          @fields = fields
          @hint = hint
        end

        def check(_cfg, _kind) = []
        def transcribe(_cfg, **) = raise(NotImplementedError)
        def speak(_cfg, **) = raise(NotImplementedError)
        def detect(_cfg, **) = raise(NotImplementedError)
      end
    end
  end
end
