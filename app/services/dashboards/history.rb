module Dashboards
  # Desfazer/refazer do editor de painel (ideia 5): cada gravação do rascunho
  # empilha o rascunho de antes (`undo`) e esvazia o `redo`; desfazer troca o
  # rascunho pelo do topo e empilha o atual no `redo` (e o refazer, o
  # contrário). `nil` = sem rascunho (a versão publicada). Publicar zera a
  # pilha (Dashboard#publish!). Guarda até MAX passos por painel.
  module History
    MAX = 40

    module_function

    def record!(dashboard, new_draft, label: nil, author: Current.user)
      Dashboard.transaction do
        if new_draft != dashboard.draft
          push(dashboard, "undo", dashboard.draft, label, author)
          dashboard.draft_steps.where(kind: "redo").delete_all
        end
        dashboard.update!(draft: new_draft)
      end
    end

    def undo!(dashboard, author: Current.user) = swap(dashboard, "undo", "redo", author)
    def redo!(dashboard, author: Current.user) = swap(dashboard, "redo", "undo", author)

    # {"undo" => [n, rótulo do próximo], "redo" => [...]}: o que os botões mostram.
    def state(dashboard)
      DashboardDraftStep::KINDS.to_h do |kind|
        list = dashboard.draft_steps.where(kind: kind)
        [ kind, [ list.count, list.order(created_at: :desc).pick(:label) ] ]
      end
    end

    # Tira o topo de `from`, guarda o rascunho atual em `to` e grava o do topo. false = pilha vazia.
    def swap(dashboard, from, to, author)
      Dashboard.transaction do
        step = dashboard.draft_steps.where(kind: from).order(created_at: :desc).lock.first or return false
        push(dashboard, to, dashboard.draft, step.label, author)
        dashboard.update!(draft: step.definition)
        step.destroy!
        true
      end
    end

    def push(dashboard, kind, definition, label, author)
      dashboard.draft_steps.create!(tenant_id: dashboard.tenant_id, kind: kind, definition: definition, label: label&.truncate(80), author: author,
                                    created_at: Time.current)
      old = dashboard.draft_steps.where(kind: kind).order(created_at: :desc).offset(MAX).pluck(:id)
      DashboardDraftStep.where(id: old).delete_all if old.any?
    end
  end
end
