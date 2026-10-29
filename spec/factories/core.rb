FactoryBot.define do
  factory :tenant do
    sequence(:name) { |n| "Empresa #{n}" }
    city { "Brasília" }
    uf { "DF" }
    ibge_code { "5300108" }
  end

  factory :user do
    tenant
    sequence(:name) { |n| "Pessoa #{n}" }
    sequence(:email) { |n| "pessoa#{n}@exemplo.com" }
    password { "12345678" }
    role { "owner" }
  end

  factory :notification do
    kind { "sistema" }
    title { "Olá" }
  end
end
