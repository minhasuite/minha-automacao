require "rails_helper"

# i18n: nenhuma chave usada no código pode faltar em pt-BR, en ou es, e todo
# plugin (PluginTexts) traz en e es para cada texto pt-BR dele. Junto com o
# spec/i18n_spec.rb (mesmas chaves nos três arquivos) e o
# raise_on_missing_translations do ambiente de teste.
RSpec.describe "Cobertura de idiomas" do
  def locales = %w[pt-BR en es]

  # t("a.b"), I18n.t("a.b"), t(".b") (relativo à view). Chave montada com
  # #{...} não entra (é conferida pelas telas nos specs de request).
  def used_keys
    files = Dir[Rails.root.join("app/**/*.{rb,erb}")] + Dir[Rails.root.join("lib/**/*.rb")]
    files.flat_map do |file|
      File.read(file).scan(/(?<![\w.])(?:I18n\.)?t\(\s*["']([.\w]+)["']/).flatten.filter_map do |key|
        next key unless key.start_with?(".")
        next unless file.include?("/app/views/")

        scope = file.split("/app/views/").last.sub(/\..*\z/, "").split("/").map { |p| p.delete_prefix("_") }
        (scope + [ key.delete_prefix(".") ]).join(".")
      end.map { |k| [ k, file.sub("#{Rails.root}/", "") ] }
    end
  end

  it "toda chave t(...) do código existe nos três idiomas" do
    missing = used_keys.flat_map do |key, file|
      locales.reject { |l| I18n.exists?(key, locale: l, fallback: false) }.map { |l| "#{l}.#{key} (#{file})" }
    end
    expect(missing.uniq).to eq([])
  end

  it "todo plugin traz en e es para cada texto pt-BR, com a mesma interpolação" do
    Rails.application.eager_load!
    plugins = ObjectSpace.each_object(Class).select { |c| c.is_a?(PluginTexts) && c.name&.safe_constantize.equal?(c) } # sem os falsos de stub_const já desfeitos
    expect(plugins.size).to be > 100
    vars = ->(s) { s.to_s.scan(/%\{(\w+)\}/).flatten.sort }
    problems = plugins.flat_map do |plugin|
      plugin.source_texts.flat_map do |key, pt|
        %w[en es].filter_map do |l|
          other = plugin.texts.dig(l, key)
          if other.blank? then "#{plugin.name} #{l}.#{key} faltando"
          elsif vars.(other) != vars.(pt) then "#{plugin.name} #{l}.#{key} com %{...} diferente"
          end
        end
      end
    end
    expect(problems).to eq([])
  end

  it "o plugin fala o idioma da tela e cai no pt-BR" do
    stub_const("PluginFalso", Class.new do
      extend PluginTexts
      translates :title
      def self.describe(title:) = (@title = title)
      describe title: "Clima"
      texts en: { title: "Weather", oi: "Hi %{n}" }, es: { title: "Tiempo" }, "pt-BR" => { oi: "Oi %{n}" }
    end)
    expect(PluginFalso.title).to eq("Clima")
    I18n.with_locale(:en) { expect([ PluginFalso.title, PluginFalso.text(:oi, n: "Ana") ]).to eq([ "Weather", "Hi Ana" ]) }
    I18n.with_locale(:es) { expect([ PluginFalso.title, PluginFalso.text(:oi, n: "Ana") ]).to eq([ "Tiempo", "Oi Ana" ]) }
    expect(PluginFalso.source_texts).to eq("title" => "Clima", "oi" => "Oi %{n}")
  end
end
