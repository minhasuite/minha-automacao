# Um passo da pilha de desfazer/refazer do rascunho de um painel (ideia 5;
# ver Dashboards::History). `kind`: undo ou redo; `definition` nulo = sem rascunho.
class DashboardDraftStep < ApplicationRecord
  KINDS = %w[undo redo].freeze

  acts_as_tenant :tenant

  belongs_to :dashboard
  belongs_to :author, class_name: "User", optional: true

  validates :kind, inclusion: { in: KINDS }
end
