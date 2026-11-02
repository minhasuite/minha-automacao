module Automations
  # Tipo de bloco da DSL (gatilho, condição ou ação) como plugin, no padrão
  # de Integrations::PLUGINS e HelperTypes::PLUGINS (F8f): a classe se
  # descreve (`describe`: chave, rótulo, campos e o que o bloco novo já traz)
  # e diz as regras dela além do tipo de cada campo (`rules`). A validação, o
  # editor de blocos, o motor e o disparo perguntam ao plugin; nenhum deles
  # tem `case` por tipo. O registro de cada lista fica em TriggerTypes,
  # ConditionTypes e ActionTypes (`PLUGINS`).
  class Block
    extend PluginTexts
    translates :label

    # Busca no registro (`extend Block::Registry` + `PLUGINS` com os nomes das classes).
    module Registry
      def plugins = self::PLUGINS.map { |name| const_get(name) }
      def catalog = plugins.index_by(&:key)
      def [](key) = catalog[key.to_s]
      def keys = plugins.map(&:key)
    end

    class << self
      attr_reader :key

      def describe(key:, label:, fields: [], defaults: {})
        @key = key
        @label = label
        @fields = fields.freeze
        @defaults = defaults.freeze
      end

      def fields = @fields || []

      # O que o bloco novo do editor já traz (passa na validação quando dá).
      def defaults = @defaults || {}

      # Mensagens além do tipo de cada campo ("informe acima de e/ou abaixo de.").
      def rules(_node) = []

      def f(...) = Dsl.f(...)
    end
  end
end
