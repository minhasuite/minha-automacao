module Dashboards
  module Widgets
    # "Falar na Alexa": campo de texto, seletor de Echo (ou todas) e microfone
    # (voz gravada, até 60 s). Envio por Alexa::Talk (web: `site_talk_path`;
    # app: `POST /api/v1/sites/:id/talk`). `binds` = as Echos do seletor (vazio
    # = todas as da casa). Vem do `custom:casa-campo-texto` do HA com `seletor`.
    class AnnounceWidget < Base
      describe type: "announce", label: "Falar na Alexa", icon: "megaphone", params: %w[placeholder], binds: true
      texts en: { label: "Talk on Alexa" },
            es: { label: "Hablar en Alexa" }

      def self.data(r, w, _binds)
        ids = Array(w["binds"]).presence
        echos = ::Alexa::Talk.speakers(r.site, ids)
        can = echos.any? { |p| SiteMembership.allowed?(r.role, :command, risk: p.risk) }
        [ { "targets" => echos.map { |p| { "id" => p.id, "name" => ::Alexa::Talk.label(p) } },
            "audio" => ::Alexa::Talk.audio?, "can_command" => can }, [] ]
      end
    end
  end
end
