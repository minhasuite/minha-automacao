# Telas do servidor no app (frente appweb): a página da web, a mesma que o
# navegador recebe, vira uma árvore de blocos que o app desenha nativo com o
# Lista Clara. Assim toda tela de configuração da web (formulário de plugin de
# integração, helper, gatilho, reparos, backups…) existe no app sem tela fixa
# por tipo: a fonte é a própria view. Ver docs/app.md ("Telas do servidor").
#
#   AppScreen.dispatch(user:, verb:, path:, fields:, request:) → { status:, page: | json: | download: | external: }
#
# Blocos (chave `t`): heading, para (runs), badge, icon, image, card, row,
# list/item, table, details, code, divider, link, form, field, submit,
# subnav, frame, poll, reload. O app ignora o tipo que não conhece.
module AppScreen
  # Controladores que não fazem sentido pelo app (sessão do navegador e instalação nova).
  DENY = %w[web/sessions web/passwords web/invites web/oauth web/onboarding web/locales].freeze
  UA = "Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0 Mobile Safari/537.36 MinhaAutomacaoApp".freeze
  ENV_KEY = "ma.app_user_id".freeze
  MAX_REDIRECTS = 5

  class Denied < StandardError; end

  module_function

  # Caminho da web que o app pode abrir: só rotas do escopo web, sem as de sessão.
  def allowed!(verb, path)
    raise Denied unless path.is_a?(String) && path.start_with?("/") && !path.start_with?("//")

    route = Rails.application.routes.recognize_path(path.split("?").first, method: verb.upcase)
    raise Denied unless route[:controller].to_s.start_with?("web/") && DENY.exclude?(route[:controller])
  rescue ActionController::RoutingError
    raise Denied
  end

  # Faz o pedido à web por dentro (mesmo processo), seguindo redirecionamentos
  # com o cookie (o flash do redirect aparece na tela seguinte).
  def dispatch(user:, verb:, path:, fields:, request:)
    allowed!(verb, path)
    cookie = nil
    status = nil
    MAX_REDIRECTS.times do
      status, headers, body = call(user, verb, path, fields, request, cookie)
      cookie = merge_cookie(cookie, headers["set-cookie"] || headers["Set-Cookie"])
      if status.between?(300, 399) && (loc = headers["location"] || headers["Location"])
        uri = URI.parse(loc)
        if uri.host.present? && uri.host != request.host
          return { status: 200, external: loc }
        end

        path = uri.request_uri
        verb = "get"
        fields = nil
        allowed!(verb, path)
        next
      end
      text = +""
      body.each { |chunk| text << chunk }
      body.close if body.respond_to?(:close)
      type = (headers["content-type"] || headers["Content-Type"]).to_s
      return { status: status, page: Transcoder.call(text, path: path) } if type.include?("html")
      return { status: status, json: (JSON.parse(text) rescue {}) } if type.include?("json") # rubocop:disable Style/RescueModifier

      return { status: status, download: path }
    end
    { status: status || 508, json: {} }
  end

  def call(user, verb, path, fields, request, cookie)
    pairs = Array(fields).filter_map { |f| [ f[0].to_s, f[1].to_s ] if f.is_a?(Array) && f[0].present? }
    url = path
    input = ""
    if verb == "get"
      url = "#{path}#{path.include?('?') ? '&' : '?'}#{URI.encode_www_form(pairs)}" if pairs.any?
    else
      input = URI.encode_www_form(pairs)
    end
    env = Rack::MockRequest.env_for(url, method: verb.upcase, input: input,
                                         "CONTENT_TYPE" => "application/x-www-form-urlencoded",
                                         "HTTP_ACCEPT" => "text/html", "HTTP_HOST" => request.host_with_port,
                                         "HTTPS" => request.ssl? ? "on" : "off", "HTTP_USER_AGENT" => UA,
                                         "HTTP_ACCEPT_LANGUAGE" => request.headers["Accept-Language"].to_s,
                                         "REMOTE_ADDR" => request.remote_ip)
    env["HTTP_COOKIE"] = cookie if cookie
    env[ENV_KEY] = user.id
    env.merge!(Rails.application.env_config)
    stack.call(env)
  end

  # A pilha de middlewares da aplicação sem o executor/reloader: o pedido
  # interno roda dentro do pedido da API, que já tem o executor (com ele o
  # estado da thread, Current e a empresa do acts_as_tenant, seria zerado).
  def stack
    @stack ||= Rails.application.middleware.dup.tap do |m|
      [ ActionDispatch::Executor, ActionDispatch::Reloader ].each { |k| m.delete(k) if m.include?(k) }
    end.build(Rails.application.routes)
  end

  def merge_cookie(old, set)
    return old if set.blank?

    jar = old.to_s.split("; ").to_h { |c| c.split("=", 2) }
    Array(set).flat_map { |s| s.split("\n") }.each do |line|
      name, value = line.split(";").first.to_s.split("=", 2)
      jar[name] = value if name.present?
    end
    jar.map { |k, v| "#{k}=#{v}" }.join("; ")
  end

  # Link de uso único (2 min) que entra no navegador como a pessoa do app e
  # abre `to` (caminho da web ou o login externo de um OAuth).
  def bridge_token(user, to) = Rails.application.message_verifier(:app_bridge).generate({ "u" => user.id, "to" => to, "j" => SecureRandom.hex(8) }, expires_in: 2.minutes)

  def redeem(token)
    data = Rails.application.message_verifier(:app_bridge).verified(token.to_s) or return
    return unless Rails.cache.write("app_bridge:#{data['j']}", 1, unless_exist: true, expires_in: 3.minutes)

    data
  end

  # HTML da web → blocos.
  class Transcoder
    SKIP = %w[script style template noscript meta link head title dialog].freeze
    INLINE = %w[span strong em b i a code kbd small time abbr br sup sub mark s u var bdi].freeze
    TONES = %w[danger success warn warning accent aquec info].freeze

    def self.call(html, path: nil) = new(html, path).call

    def initialize(html, path)
      @doc = Nokogiri::HTML5(html.to_s)
      @path = path
      @labels = {}
    end

    def call
      menu = @doc.css("aside#side nav a[href]").map { |a| { label: squish(a.text), href: a["href"], icon: icon_of(a) } }
      root = @doc.at_css("main#conteudo") || @doc.at_css("main") || @doc.at_css("body") || @doc
      @doc.css("label[for]").each { |l| @labels[l["for"]] = squish(l.text) }
      flash = root.css(".ss-flash").map { |f| { tone: f["class"].to_s.include?("danger") ? "danger" : "success", text: squish(f.at_css("span")&.text || f.text) } }
      root.css(".ss-flash, #flash").each(&:remove)
      page = { path: @path, title: squish(@doc.at_css("title")&.text.to_s.split(" — ").first), flash: flash, menu: menu }
      if (h1 = root.at_css("h1"))
        header = h1.ancestors.find { |a| a.parent == root || a.parent&.name == "main" } || h1
        page[:title] = squish(h1.text)
        back = header.css("a[href]").find { |a| icon_of(a) == "arrow-left" }
        page[:back] = back["href"] if back
        sub = header.at_css("p.text-muted, p.text-sm")
        page[:subtitle] = squish(sub.text) if sub
        [ back, sub, h1 ].compact.each(&:remove)
        page[:actions] = header.equal?(h1) ? [] : blocks(header)
        header.remove
      end
      page[:blocks] = blocks(root)
      page
    end

    private

    def blocks(el) = el.children.flat_map { |c| node(c) }
    def content(el) = inline_only?(el) ? inline(el) : blocks(el)

    def node(n)
      return text_block(n) if n.text?
      return [] unless n.element? && !hidden?(n)

      cls = classes(n)
      return poll(n) if data_controllers(n).include?("poll")
      return [ { t: "reload", every: n["data-reload-every-value"].to_i.nonzero? || 5000, c: blocks(n) } ] if data_controllers(n).include?("reload")

      case n.name
      when "svg" then (ic = n["data-icon"]) ? [ { t: "icon", n: ic } ] : []
      when "img" then n["src"].present? ? [ { t: "image", src: n["src"], alt: n["alt"].to_s } ] : []
      when "h1", "h2", "h3", "h4", "h5", "h6" then [ { t: "heading", level: n.name[1].to_i, s: squish(n.text), icon: icon_of(n) }.compact ]
      when "hr" then [ { t: "divider" } ]
      when "pre" then [ { t: "code", s: n.text.strip } ]
      when "a" then link(n)
      when "form" then form(n)
      when "input", "select", "textarea" then field(n)
      when "button" then button(n)
      when "label" then label(n)
      when "table" then table(n)
      when "details" then [ { t: "details", summary: squish(n.at_css("summary")&.text.to_s), open: n.key?("open"), c: n.children.reject { |c| c.name == "summary" }.flat_map { |c| node(c) } } ]
      when "ul", "ol" then list(n)
      when "turbo-frame"
        n["src"].present? ? [ { t: "frame", id: n["id"], src: n["src"] } ] : blocks(n)
      when "nav"
        return [ { t: "subnav", items: n.css("a[href]").map { |a| { label: squish(a.text), href: a["href"], icon: icon_of(a), current: a["aria-current"] == "page" } } } ] if cls.include?("ss-subnav") || n.css("a[href]").size >= 3

        blocks(n)
      else
        return [ { t: "badge", s: squish(n.text), tone: tone(cls) || "ghost" } ] if cls.any? { |c| c.start_with?("ss-badge") }
        return inline(n) if inline_only?(n)

        if row?(cls) && n.element_children.size > 1
          # Cada filho do flex é um item da linha (o que ele tiver de vários blocos vira coluna).
          kids = n.children.flat_map { |c| r = node(c); r.size > 1 ? [ { t: "col", c: r } ] : r }
          return kids.size > 1 ? [ { t: "row", c: kids } ] : kids
        end
        kids = blocks(n)
        return [] if kids.empty?
        return [ { t: "card", c: kids } ] if cls.include?("ss-card") || cls.include?("ss-panel")

        kids
      end
    end

    def hidden?(n)
      return true if SKIP.include?(n.name) || n.key?("hidden") || n["data-app"] == "skip"
      return true if n["aria-hidden"] == "true" && n.name != "svg"

      cls = classes(n)
      cls.include?("hidden") || cls.include?("sr-only") || cls.include?("ss-skip")
    end

    def classes(n) = n["class"].to_s.split
    def data_controllers(n) = n["data-controller"].to_s.split
    def squish(s) = s.to_s.gsub(/\s+/, " ").strip
    def icon_of(n) = n.at_css("svg[data-icon]")&.[]("data-icon")
    def tone(cls) = cls.filter_map { |c| c[/\A(?:ss-badge|text|bg)-(#{TONES.join('|')})/o, 1] }.first&.sub("warning", "warn")
    def row?(cls) = (cls.include?("flex") || cls.include?("inline-flex")) && !cls.include?("flex-col") && cls.none? { |c| c.start_with?("grid") }

    def inline_only?(n)
      n.element_children.none? { |c| !INLINE.include?(c.name) && c.name != "svg" && c.name != "img" } &&
        n.css("*").none? { |c| (!INLINE.include?(c.name) && !%w[svg path img circle rect line polyline g].include?(c.name)) || classes(c).any? { |k| k.start_with?("ss-btn") } }
    end

    def text_block(n)
      s = squish(n.text)
      s.empty? ? [] : [ { t: "para", runs: [ { s: s } ] } ]
    end

    # Parágrafo: pedaços de texto com estilo (negrito, mono, apagado, link, selo).
    def inline(n)
      runs = []
      walk = lambda do |el, style|
        el.children.each do |c|
          next if c.element? && hidden?(c)

          if c.text?
            s = c.text.gsub(/\s+/, " ")
            runs << style.merge(s: s) unless s.strip.empty? && runs.empty?
          elsif c.name == "br"
            runs << style.merge(s: "\n")
          elsif c.name == "svg"
            runs << { icon: c["data-icon"] } if c["data-icon"] && runs.empty?
          elsif c.element?
            walk.call(c, style.merge(run_style(c)).compact)
          end
        end
      end
      walk.call(n, run_style(n).compact)
      runs.each { |r| r[:s] = r[:s].to_s.lstrip if r.equal?(runs.first) }
      runs.reject! { |r| r[:s].to_s.empty? && !r[:icon] }
      return [] if runs.empty?

      out = { t: "para", runs: runs }
      cls = classes(n)
      out[:size] = "small" if cls.include?("text-xs") || cls.include?("text-sm") || n.name == "small"
      out[:size] = "big" if cls.any? { |c| c.match?(/\Atext-(lg|xl|2xl|3xl|4xl)\z/) }
      [ out ]
    end

    def run_style(el)
      cls = classes(el)
      { b: (true if %w[strong b].include?(el.name) || cls.any? { |c| c.match?(/\Afont-(bold|semibold|extrabold)\z/) }),
        m: (true if %w[code kbd].include?(el.name) || cls.include?("font-mono") || cls.include?("num")),
        mu: (true if cls.include?("text-muted") || cls.include?("text-ink-2")),
        tone: tone(cls), badge: (tone(cls) || "ghost" if cls.any? { |c| c.start_with?("ss-badge") }),
        href: (el["href"] if el.name == "a" && el["href"].present? && !el["href"].start_with?("#")) }
    end

    def link(n)
      href = n["href"].to_s
      return blocks(n) if href.empty? || href.start_with?("#") || href.start_with?("javascript:")

      cls = classes(n)
      out = { t: "link", href: href, s: squish(n.text), icon: icon_of(n), kind: btn_kind(cls),
              method: n["data-turbo-method"], confirm: n["data-turbo-confirm"],
              ext: (true if href.match?(%r{\Ahttps?://})), bridge: (true if href.include?("redirect_uri=")),
              current: (true if n["aria-current"] == "page") }.compact
      out[:c] = blocks(n) unless out[:kind] || inline_only?(n)
      out.delete(:s) if out[:c]
      [ out ]
    end

    def btn_kind(cls)
      return unless cls.any? { |c| c.start_with?("ss-btn") }

      %w[primary danger outline ghost].find { |k| cls.include?("ss-btn-#{k}") } || "outline"
    end

    def form(n)
      method = n.at_css("input[name=_method]")&.[]("value") || n["method"].presence || "get"
      hidden = n.css("input[type=hidden]").reject { |i| i["name"].blank? || i["name"] == "authenticity_token" || i["name"] == "_method" }.map { |i| [ i["name"], i["value"].to_s ] }
      confirm = n["data-turbo-confirm"] || n.at_css("[data-turbo-confirm]")&.[]("data-turbo-confirm")
      out = { t: "form", action: n["action"].presence || @path, method: method.downcase, hidden: hidden, confirm: confirm, c: blocks(n) }.compact
      classes(n).include?("ss-card") ? [ { t: "card", c: [ out ] } ] : [ out ]
    end

    def field(n)
      type = n.name == "input" ? (n["type"].presence || "text").downcase : n.name
      return [ { t: "submit", s: n["value"].to_s, name: n["name"], value: n["value"], kind: btn_kind(classes(n)) || "primary", confirm: n["data-turbo-confirm"] }.compact ] if type == "submit"
      return [] if type == "hidden" || n["name"].blank? || %w[button image reset].include?(type)

      out = { t: "field", kind: type, name: n["name"], label: @labels[n["id"]], placeholder: n["placeholder"],
              required: (true if n.key?("required")), disabled: (true if n.key?("disabled")),
              min: n["min"], max: n["max"], step: n["step"], hint: hint_for(n) }.compact
      case type
      when "select"
        out[:multiple] = true if n.key?("multiple")
        out[:options] = n.css("option").map do |o|
          { label: squish(o.text), value: o["value"] || squish(o.text), group: o.parent.name == "optgroup" ? o.parent["label"] : nil }.compact
        end
        sel = n.css("option[selected]").map { |o| o["value"] || squish(o.text) }
        out[:value] = out[:multiple] ? sel : (sel.first || out[:options].first&.dig(:value))
      when "textarea" then out[:value] = n.text
      when "checkbox", "radio"
        out[:value] = n["value"] || "on"
        out[:checked] = n.key?("checked")
      else out[:value] = n["value"].to_s
      end
      [ out ]
    end

    # Dica de um campo: o `aria-describedby` ou o texto pequeno logo depois.
    def hint_for(n)
      if (ids = n["aria-describedby"]).present?
        txt = ids.split.filter_map { |id| @doc.at_css("##{id}")&.text }.join(" ")
        return squish(txt).presence
      end
      sib = n.next_element
      squish(sib.text).presence if sib && sib.name == "p" && classes(sib).include?("text-xs")
    end

    def label(n)
      inner = n.css("input, select, textarea").find { |i| i["type"] != "hidden" }
      return [] if n["for"].present? && !inner # vira o rótulo do campo
      return blocks(n) unless inner

      text = squish(n.children.reject { |c| c.element? && (%w[input select textarea].include?(c.name) || c.at_css("input, select, textarea")) }.map(&:text).join(" "))
      field(inner).map { |f| f.merge(label: f[:label] || text.presence).compact }
    end

    def button(n)
      type = (n["type"].presence || "submit").downcase
      return [] unless type == "submit"

      [ { t: "submit", s: squish(n.text), icon: icon_of(n), name: n["name"], value: n["value"], kind: btn_kind(classes(n)) || "primary",
          confirm: n["data-turbo-confirm"] }.compact ]
    end

    def list(n)
      items = n.element_children.select { |c| c.name == "li" && !hidden?(c) }.map { |li| { t: "item", c: content(li) } }.reject { |i| i[:c].empty? }
      items.empty? ? [] : [ { t: "list", c: items } ]
    end

    def table(n)
      head = n.css("thead th").map { |th| squish(th.text) }
      rows = n.css("tbody tr").map { |tr| tr.css("td, th").map { |td| content(td) } }
      [ { t: "table", head: head, rows: rows } ]
    end

    def poll(n)
      [ { t: "poll", url: n["data-poll-url-value"], every: n["data-poll-every-value"].to_i.nonzero? || 3000, c: blocks(n) } ]
    end
  end
end
