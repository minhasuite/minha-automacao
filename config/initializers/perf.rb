# Desempenho por tela na Saúde (Perf): soma na memória, junta no cache uma vez por minuto.
Rails.application.config.after_initialize { Perf.subscribe! }
