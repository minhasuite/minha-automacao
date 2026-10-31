# Modo sombra (F10): o MA roda as automações com os eventos reais, mas nada
# sai para fora. Serve para qualquer migração (de outro sistema ou de uma
# versão nova de automação): liga em uma automação, script ou cena
# (`shadow`), no local inteiro (`sites.shadow`) ou na instalação
# (`tenants.settings["shadow"]`).
#
# Como segura:
# - O motor (Automations::Engine) pergunta ao plugin de cada ação se ela é
#   segura na sombra (`shadow_safe?`: controle, variável, espera, leitura,
#   comando em helper interno, chamar script). O padrão é NÃO: ação nova nasce
#   segurada. A segurada roda como simulação (o mesmo caminho do "Simular")
#   e vira um ShadowAction "teria feito".
# - Rede de segurança embaixo, para qualquer caminho que escape: com uma
#   execução em sombra na thread (`current`) ou comando automático num local
#   em sombra, `Points::Command.call` não cria o comando (registra e levanta
#   Blocked) e `Notifier`, `SafeHttp` e `Ai::Request` levantam Blocked.
#   Helper e script (driver virtual, sem aparelho) rodam e ficam registrados
#   com `executed`.
module Shadow
  class Blocked < Points::Command::Error
    def initialize(what) = super(:shadow, "Em sombra: #{what} não foi enviado.")
  end

  # O que está em sombra na thread: execução, cena ou o local (primitivas).
  Context = Data.define(:site_id, :run, :scene)

  module_function

  def global?(tenant) = tenant&.settings.to_h["shadow"] == true
  def site?(site) = site.present? && (site.shadow || global?(site.tenant))

  # Automação, script ou cena em sombra (a própria marca, o local ou a instalação).
  def active?(record) = record.shadow || site?(record.site)

  def current = Thread.current[:shadow]

  def within(site_id:, run: nil, scene: nil)
    previous = current
    Thread.current[:shadow] = Context.new(site_id: site_id, run: run, scene: scene)
    yield
  ensure
    Thread.current[:shadow] = previous
  end

  # Primitivas do local (espelho, agenda, aviso, alerta) num local em sombra.
  def for_site(site, &)
    return yield unless site?(site) && current.nil?

    within(site_id: site.id, &)
  end

  # Helper que não comanda outros pontos e ponto de script: rodam na sombra.
  def internal?(point)
    return false unless point.device.virtual?
    return true if point.capability == "script"

    (plugin = point.helper_type) ? !plugin.drives_points? : false
  end

  # Chamado pelo Points::Command depois de validar. Interno: registra e
  # deixa seguir. Senão: registra e levanta Blocked.
  def intercept!(point, command, value, source)
    ctx = current || (Context.new(site_id: point.site_id, run: nil, scene: nil) if source == "automation" && site?(point.site))
    return unless ctx

    title = "#{Points::Timeline::COMMAND_LABELS.fetch(command.to_s, command.to_s)} #{point.name}#{" (#{value})" unless value.nil? || value.is_a?(Hash)}"
    internal = internal?(point)
    record!(ctx, action: "command", title: title, effects: [ { "point_id" => point.id, "command" => command.to_s, "value" => value } ],
                 executed: internal, detail: (internal ? "Interno (helper ou script): executado" : nil))
    raise Blocked, title unless internal
  end

  # Aviso, HTTP, IA: com sombra na thread, não sai.
  def block!(what)
    ctx = current or return
    record!(ctx, action: "blocked", title: what.to_s.truncate(250), detail: "Segurado pela rede de segurança")
    raise Blocked, what
  end

  def record!(ctx, action:, title:, detail: nil, effects: [], executed: false)
    run = ctx.run
    ShadowAction.create!(site_id: ctx.site_id, automation_id: run&.automation_id, automation_run_id: (run.id if run&.persisted?),
                         scene_id: ctx.scene&.id, action: action, title: title.to_s.truncate(250).presence || action,
                         detail: detail.to_s.truncate(500).presence, effects: effects, executed: executed)
  end
end
