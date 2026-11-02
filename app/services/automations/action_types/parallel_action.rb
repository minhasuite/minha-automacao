module Automations
  module ActionTypes
    # Em paralelo (ondaA1, A7; o `parallel` do HA): cada bloco de dentro é um
    # ramo (vários passos num ramo = bloco "Sequência"). Cada ramo roda como
    # execução própria da mesma automação (trace e esperas dele) e esta só
    # segue quando todos terminam; ramo que falha faz esta falhar. O ramo
    # começa com as variáveis daqui e não devolve variáveis (como no HA). Na
    # simulação os ramos rodam em sequência dentro desta execução.
    class ParallelAction < Base
      MAX_BRANCHES = 10

      def self.control? = true

      describe key: "parallel", label: "Em paralelo", defaults: { "actions" => [] },
               fields: [ f("actions", :actions, "Ao mesmo tempo (cada bloco é um ramo)", en: "At the same time (each block is a branch)", es: "Al mismo tiempo (cada bloque es una rama)") ]
      texts "pt-BR" => { few: "use de 2 a %{max} blocos (ramos).", title: "Em paralelo: %{n} ramos", wait: "Esperando os ramos terminarem", done: "Ramos terminaram", branch: "Ramo %{n}: %{title}" },
            en: { label: "In parallel", few: "use 2 to %{max} blocks (branches).", title: "In parallel: %{n} branches", wait: "Waiting for the branches", done: "Branches finished", branch: "Branch %{n}: %{title}" },
            es: { label: "En paralelo", few: "usa de 2 a %{max} bloques (ramas).", title: "En paralelo: %{n} ramas", wait: "Esperando las ramas", done: "Las ramas terminaron", branch: "Rama %{n}: %{title}" }

      def self.rules(node) = Array(node["actions"]).size.between?(2, MAX_BRANCHES) ? [] : [ text(:few, max: MAX_BRANCHES) ]

      # Simulação: os ramos entram no programa, em sequência. De verdade: um
      # passo só; cada execução filha compila o ramo dela (Engine#spawn_branch).
      def self.compile(e, node, path)
        return e.compile(node["actions"], "#{path}.actions") if e.dry_run?

        e.emit([ :act, path, node ])
      end

      def self.call(e, path, node)
        branches = Array(node["actions"])
        children = branches.each_with_index.map do |b, i|
          e.spawn_branch("#{path}.actions.#{i}", text(:branch, n: i + 1, title: ActionTypes[b["type"]]&.label || b["type"]))
        end
        e.join_branches(path, children, text(:title, n: branches.size), text(:wait), text(:done))
      end
    end

    # Sequência (ondaA1, A7; o `sequence` do HA): agrupa passos num bloco só
    # (um ramo do "Em paralelo" com vários passos).
    class SequenceAction < Base
      def self.control? = true

      describe key: "sequence", label: "Sequência", defaults: { "actions" => [] },
               fields: [ f("actions", :actions, "Passos", en: "Steps", es: "Pasos") ]
      texts en: { label: "Sequence" }, es: { label: "Secuencia" }

      def self.compile(e, node, path) = e.compile(node["actions"], "#{path}.actions")
    end
  end
end
