module Dashboards
  # Comparar versões (ideia 5): diferença legível entre duas definições, por
  # visão, seção e widget, para a tela "lado a lado" do editor. Nada aqui
  # sabe de tipo de widget: compara chaves (`changes` = [chave, antes, depois]).
  #
  #   Diff.call(a, b) → [{ "id", "title", "status", "changes", "sections" => [...], "widgets" => [...] }]
  #   status: added, removed, changed, moved (widget que trocou de seção ou de lugar), same.
  module Diff
    SHOWN = 120 # tamanho máximo do valor na tela

    module_function

    # `names`: id do ponto → nome (o widget sem rótulo aparece pelo ponto).
    def call(a, b, names: {})
      va = index(Array(a.to_h["views"]))
      vb = index(Array(b.to_h["views"]))
      (va.keys | vb.keys).map { |id| view(va[id], vb[id], names) }
    end

    # Só o que mudou (para o resumo "n mudanças").
    def count(diff) = diff.sum { |v| (v["status"] == "same" ? 0 : 1) + v["sections"].count { |s| s["status"] != "same" } + v["widgets"].count { |w| w["status"] != "same" } }

    def view(a, b, names = {})
      sa = index(Array(a&.dig("sections")))
      sb = index(Array(b&.dig("sections")))
      wa = widgets(a)
      wb = widgets(b)
      ws = (wa.keys | wb.keys).map { |id| widget(wa[id], wb[id], names) }
      ss = (sa.keys | sb.keys).map { |id| section(sa[id], sb[id]) }
      changes = props(a, b, %w[sections badges])
      status = status(a, b) { changes.any? || ss.any? { |s| s["status"] != "same" } || ws.any? { |w| w["status"] != "same" } }
      { "id" => (a || b)["id"], "title" => (b || a)["title"], "status" => status, "changes" => changes, "sections" => ss, "widgets" => ws }
    end

    def section(a, b)
      changes = props(a, b, %w[widgets])
      { "id" => (a || b)["id"], "title" => (b || a)["title"], "status" => status(a, b) { changes.any? }, "changes" => changes }
    end

    def widget(a, b, names = {})
      changes = props(a&.dig("w"), b&.dig("w"), %w[widgets])
      moved = a && b && (a["section"] != b["section"] || reordered?(a, b))
      status = status(a, b) { changes.any? }
      status = "moved" if status == "same" && moved
      { "id" => (a || b)["w"]["id"], "label" => label((b || a)["w"], names), "type" => (b || a)["w"]["type"], "status" => status, "changes" => changes,
        "from" => a&.slice("section_title", "index"), "to" => b&.slice("section_title", "index") }
    end

    # Mudou de lugar entre os irmãos que ficaram (sair ou entrar outro não conta).
    def reordered?(a, b)
      id = a["w"]["id"]
      (a["siblings"] & b["siblings"]).index(id) != (b["siblings"] & a["siblings"]).index(id)
    end

    def status(a, b)
      return "added" unless a
      return "removed" unless b

      yield ? "changed" : "same"
    end

    # [chave, antes, depois] das chaves que mudaram (fora as listas filhas).
    def props(a, b, skip)
      return [] unless a && b

      (a.keys | b.keys).without(*skip, "id").sort.filter_map { |k| [ k, show(a[k]), show(b[k]) ] unless a[k] == b[k] }
    end

    def show(v)
      return nil if v.nil?

      (v.is_a?(String) ? v : v.to_json).truncate(SHOWN)
    end

    # Nome do widget na tela: o rótulo, o título, o nome do ponto (`names`: id → nome) ou o tipo.
    def label(w, names = {}) = w["label"].presence || w["title"].presence || names[w["bind"]] || Schema.labels.fetch(w["type"], w["type"].to_s)

    def index(list) = list.select { |x| x.is_a?(Hash) && x["id"] }.index_by { |x| x["id"] }

    # Widgets da visão (com os de dentro das pilhas): id → {w, section, section_title, index}.
    def widgets(view)
      Array(view&.dig("sections")).each_with_object({}) do |s, out|
        walk(Array(s["widgets"]), s, out)
      end
    end

    def walk(list, s, out, parent = nil)
      siblings = list.filter_map { |w| w["id"] if w.is_a?(Hash) }
      list.each_with_index do |w, i|
        next unless w.is_a?(Hash) && w["id"]

        out[w["id"]] = { "w" => w, "section" => parent || s["id"], "section_title" => s["title"], "index" => i, "siblings" => siblings }
        walk(Array(w["widgets"]), s, out, w["id"]) if w["widgets"].is_a?(Array)
      end
    end
  end
end
