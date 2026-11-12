require "rails_helper"
require "open3"

# O supervisor roda o lib/app_catalog.rb SEM Rails: método do ActiveSupport
# (presence, blank?…) passa nos specs com Rails e quebra a instalação de
# verdade (12/11/2026: "undefined method `presence'"). Aqui monta o container de
# todo app do catálogo num Ruby limpo.
RSpec.describe "AppCatalog em Ruby puro" do # rubocop:disable RSpec/DescribeClass
  it "monta o container de todos os apps sem o ActiveSupport" do
    script = <<~RUBY
      require "./lib/app_catalog"
      raise "ActiveSupport carregado" if defined?(ActiveSupport)
      AppCatalog.all.each do |app|
        opts = app.options.to_h { |o| [ o["key"], o["default"] ] }
        app.container_body(opts, network: "bridge", restart: "no", server_env: {})
      end
      puts "ok \#{AppCatalog.all.size}"
    RUBY
    out, status = Open3.capture2e({ "RUBYOPT" => nil, "BUNDLE_GEMFILE" => nil }, "ruby", "--disable-gems", "-e", script, chdir: Rails.root.to_s)
    expect(status).to be_success, out
    expect(out).to start_with("ok ")
  end
end
