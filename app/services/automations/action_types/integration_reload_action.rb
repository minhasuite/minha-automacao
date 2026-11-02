module Automations
  module ActionTypes
    # "Recarregar integração" (Lote 7; `reload_config_entry` e `<domínio>.reload`
    # do HA): põe na fila a varredura de novo das integrações daquele tipo no
    # local (refaz a conexão e o inventário), como o "Sincronizar" da tela.
    # Fala com a rede: em sombra fica segurada (padrão dos plugins).
    class IntegrationReloadAction < Base
      describe key: "integration_reload", label: "Recarregar integração",
               fields: [ f("integration", :text, "Tipo de integração (ex.: tuya, alexa)", required: true, en: "Integration type (e.g. tuya, alexa)", es: "Tipo de integración (ej.: tuya, alexa)") ]
      texts "pt-BR" => { unknown: "tipo de integração não existe (%{keys})." },
            en: { label: "Reload integration", unknown: "integration type doesn't exist (%{keys})." },
            es: { label: "Recargar integración", unknown: "el tipo de integración no existe (%{keys})." }

      def self.rules(node) = Integrations.plugin(node["integration"]) ? [] : [ text(:unknown, keys: Integrations.plugins.map(&:key).join(", ")) ]

      def self.call(e, _path, node)
        list = e.ctx.site.integrations.select { |i| i.plugin&.key == node["integration"] }
        title = "Recarregar #{Integrations.plugin(node['integration'])&.title || node['integration']}"
        return [ title, "simulated", "Não recarregada (simulação): #{list.size}" ] if e.dry_run?
        raise Engine::Failure, "Nenhuma integração desse tipo no local." if list.empty?

        list.each { |i| Integrations.start_sync!(i) }
        [ title, "ok", "#{list.size} na fila" ]
      end
    end
  end
end
