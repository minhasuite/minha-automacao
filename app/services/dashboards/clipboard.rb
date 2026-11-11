module Dashboards
  # Área de transferência do editor de painel (ideia 4), no servidor e por
  # pessoa (`users.dashboard_prefs["clipboard"]`): copiar um widget ou uma
  # seção num painel e colar em outra visão ou outro painel da mesma empresa.
  # Só uma coisa por vez; o "colar estilo" usa o widget copiado.
  module Clipboard
    KEY = "clipboard".freeze
    KINDS = %w[widget section].freeze
    MAX_BYTES = 64.kilobytes

    module_function

    # false = grande demais.
    def copy!(user, kind, item, label: nil)
      raise ArgumentError, kind unless KINDS.include?(kind)
      return false if item.to_json.bytesize > MAX_BYTES

      data = { "kind" => kind, "item" => item, "label" => label.to_s.truncate(80).presence, "tenant_id" => user.tenant_id, "at" => Time.current.iso8601 }.compact
      user.update!(dashboard_prefs: user.dashboard_prefs.merge(KEY => data))
      true
    end

    # {kind, item, label} ou nil (vazio, ou de outra empresa).
    def read(user)
      data = user.dashboard_prefs[KEY]
      data if data.is_a?(Hash) && KINDS.include?(data["kind"]) && data["item"].is_a?(Hash) && data["tenant_id"] == user.tenant_id
    end

    def clear!(user) = user.update!(dashboard_prefs: user.dashboard_prefs.except(KEY))
  end
end
