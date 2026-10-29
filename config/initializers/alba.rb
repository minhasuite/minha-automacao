require "alba"
Alba.inflector = :active_support
# Encoder do ActiveSupport: Time vira ISO8601 ("2026-10-06T12:00:00.000-03:00"),
# que o DateTime.parse do Dart entende. O JSON puro emitiria o to_s do Ruby.
Alba.backend = :active_support
