// Import and register all your controllers from the importmap via controllers/**/*_controller
import { application } from "controllers/application"
import { eagerLoadControllersFrom } from "@hotwired/stimulus-loading"
eagerLoadControllersFrom("controllers", application)
// Controllers da gem componentes_ui (data-controller="ss-*"; o engine faz o pin).
// Os do produto não usam o prefixo ss-, então não há colisão de nome.
eagerLoadControllersFrom("componentes_ui/controllers", application)
