# Blueprints prontos (F8f): um JSON por modelo em config/blueprints, no
# formato do Blueprint (name, description, domain, mode, inputs,
# definition). Genéricos, nada da casa. `sync_builtin!` cria ou atualiza os
# do local ao abrir a aba; mudar o arquivo sobe a versão e propaga para as
# automações criadas dele (Blueprint#propagate!).
module Blueprints
  DIR = Rails.root.join("config/blueprints")

  module_function

  def builtin = Dir[DIR.join("*.json")].sort.to_h { |f| [ "builtin:#{File.basename(f, '.json')}", JSON.parse(File.read(f)) ] }

  def sync_builtin!(site)
    builtin.each do |source, attrs|
      bp = site.blueprints.find_or_initialize_by(source: source)
      bp.assign_attributes(attrs.slice("name", "description", "domain", "mode", "inputs", "definition"))
      bp.save! if bp.changed?
    end
  end
end
