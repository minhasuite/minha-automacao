module Dashboards
  # Antes → depois de um painel, visão a visão (a prévia do "Arrumar esta
  # visão", o resultado da montagem por frase e a tela "Mudanças"): selos e
  # seções com os nomes dos widgets, para conferir antes de publicar. Só lê.
  module Diff
    Side = Data.define(:badges, :sections)
    View = Data.define(:id, :title, :status, :before, :after)

    module_function

    # → [View]; `only`: ids das visões (nil = todas). `names`: {id do ponto => nome}.
    def call(before, after, names: {}, only: nil)
      b = Array(before.to_h["views"]).select { _1.is_a?(Hash) }.index_by { _1["id"] }
      a = Array(after.to_h["views"]).select { _1.is_a?(Hash) }.index_by { _1["id"] }
      ids = (a.keys + b.keys).uniq
      ids &= Array(only) if only
      ids.map do |id|
        bv = b[id]
        av = a[id]
        status = if bv.nil? then :added
        elsif av.nil? then :removed
        elsif bv == av then :same
        else :changed
        end
        View.new(id: id, title: (av || bv)["title"], status: status, before: side(bv, names), after: side(av, names))
      end
    end

    def side(view, names)
      return nil if view.nil?

      Side.new(badges: Array(view["badges"]).map { label(_1, names) },
               sections: Array(view["sections"]).map { |s| { "title" => s["title"], "widgets" => flat(s["widgets"]).map { label(_1, names) } } })
    end

    def flat(list) = Array(list).flat_map { |w| w.is_a?(Hash) && w["widgets"].is_a?(Array) ? flat(w["widgets"]) : [ w ] }.select { _1.is_a?(Hash) }

    def label(w, names)
      w["name"].presence || w["label"].presence || w["title"].presence || names[w["bind"]] ||
        (Schema.labels[w["type"]] || w["type"]).to_s
    end
  end
end
