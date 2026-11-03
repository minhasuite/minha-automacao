# resto (7.13): o catálogo de aplicativos junta os apps dos repositórios de terceiros.
Rails.application.config.to_prepare { AppCatalog.extra = -> { AppRepos.manifests } }
