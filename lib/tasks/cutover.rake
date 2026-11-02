# Troca de sistema (docs/cutover.md): `rake cutover:check` lista o que falta
# em cada instalação (sai com 1 se faltar algo).
namespace :cutover do
  desc "Pré-checagens da troca de sistema (sombra, integrações, backup externo, app, push)"
  task check: :environment do
    ready = Tenant.order(:created_at).map do |tenant|
      puts "== #{tenant.name}"
      items = ActsAsTenant.with_tenant(tenant) { Cutover.items(tenant) }
      items.each { |i| puts "  [#{i.status == 'ok' ? 'ok' : 'falta'}] #{i.title}: #{i.detail}" }
      items.all? { |i| i.status == "ok" }
    end
    exit(1) unless ready.all?
  end
end
