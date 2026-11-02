module Automations
  # Templates do HA na hora (ondaA1, A9): qualquer texto ou expressão das
  # automações, scripts, helpers e ferramentas aceita o Jinja do HA como se
  # escreve lá (`{{ states('sensor.temp') | float > 28 }}`,
  # `{{ is_state('light.sala', 'on') }}`, `{% if ... %}`, `area_entities`,
  # `now().hour`, `iif`, `state_attr`, `has_value`...). O tradutor do
  # importador (Blueprints::Jinja) vira Liquid ou a expressão daqui, e a
  # entidade do HA vira o ponto: o importado do HA (de-para ExternalRef) ou o
  # ponto com a mesma chave (`sensor.temp`). Texto que já é Liquid válido
  # não muda (o Liquid ganha).
  module HaTemplates
    SOURCE = "home_assistant".freeze
    MARK = /\[\[([a-z0-9_.]+)\]\]/

    module_function

    def jinja?(src) = src.is_a?(String) && (src.include?("{{") || src.include?("{%"))

    def liquid_ok?(src)
      Liquid::Template.parse(src, error_mode: :strict)
      true
    rescue Liquid::Error
      false
    end

    # Texto → Liquid (nil se não é Jinja do HA que traduz).
    def text(src, site)
      return unless jinja?(src) && !liquid_ok?(src)

      out = translator(site).text(src) or return
      out.gsub(MARK, '\1')
    end

    # "{{ expressão }}" → expressão daqui (nil se não traduz).
    def expr(src, site)
      return unless src.is_a?(String) && src.strip.start_with?("{{")

      out = translator(site).expr(src) or return
      out.gsub(MARK, '\1')
    end

    # Entidade do HA → chave do ponto (sem ponto: a própria entidade; a
    # execução avisa "não é ponto deste local", como com chave errada).
    def translator(site)
      refs = site ? ExternalRef.map_for(site, SOURCE, "Point") : {}
      keys = site ? site.points.pluck(:id, :key).to_h : {}
      names = site ? site.areas.pluck(:id, :name) : []
      areas = names.to_h.merge(names.to_h { |_, n| [ n.parameterize(separator: "_"), n ] }) # id daqui ou o id do HA ("sala_de_estar")
      labels = Tag.pluck(:name).to_h { |n| [ n.parameterize(separator: "_"), n ] }
      Blueprints::Jinja.new(->(e) { keys[refs[e]] || e }, areas: areas, labels: labels)
    end
  end
end
