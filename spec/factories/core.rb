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

FactoryBot.define do
  factory :site do
    sequence(:name) { |n| "Casa #{n}" }
  end

  factory :area do
    site
    sequence(:name) { |n| "Sala #{n}" }
  end

  factory :device do
    area { nil }
    site { area&.site || association(:site) }
    sequence(:name) { |n| "Interruptor #{n}" }
  end

  factory :point do
    device
    site { device.site }
    sequence(:name) { |n| "Luz #{n}" }
    capability { "onoff" }
  end

  factory :site_membership do
    site
    user { association :user, tenant: site.tenant }
    role { "resident" }
  end
end
