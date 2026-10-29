# Usuário de teste padrão da suíte (teste@teste.com / 12345678), só para dev:
#   bin/rails runner db/seeds/test_user.rb
# Idempotente.
abort "test_user é só para desenvolvimento" if Rails.env.production?

user = User.find_by(email: "teste@teste.com")
if user
  user.update!(password: "12345678")
else
  tenant = Tenant.create!(name: "Casa de Teste", trade_name: "Casa Teste", city: "Brasília", uf: "DF", ibge_code: "5300108")
  user = User.create!(tenant: tenant, name: "Teste", email: "teste@teste.com", password: "12345678", role: "owner")
end
puts "teste@teste.com / 12345678 (empresa #{user.tenant_id})"
