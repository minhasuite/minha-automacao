module GoogleHome
  # Relator do StateReport (ondaC1, C6): ponto exposto ao Google num local
  # com conta de serviço e conta ligada → Report State no HomeGraph.
  class Reporter
    def self.wants?(point) = GoogleHome.exposed?(point) && HomeGraph.configured?(point.site)
    def self.report!(site, points) = HomeGraph.report_state!(site, points)
  end
end
