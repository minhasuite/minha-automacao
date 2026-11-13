module Pairing
  # "Substitui um aparelho existente": quais aparelhos do local o que acabou de
  # parear deve estar substituindo, do mais provável ao menos. É o que a pessoa
  # fazia de cabeça na migração (docs/integracoes.md, "Zigbee"):
  # - capacidade: pontos que combinam pela sugestão do `Devices::Replace`
  #   (capacidade, classe, unidade, propriedade equivalente, nome);
  # - bateria: aparelho de pilha substitui aparelho que tinha bateria;
  # - estado: o valor de agora dos pares bate (ex.: os dois "fechado");
  # - ordem: o antigo parou de responder há pouco (foi resetado agora), e o que
  #   parou por último vem primeiro; o que está respondendo agora perde nota;
  # - mesmo fabricante/modelo.
  # Só entra quem tem ao menos um ponto que combina.
  module Suggest
    Item = Data.define(:device, :score, :reasons, :mapped, :total)

    BATTERY = 5
    STATE = 2
    SILENT = 4
    # Parou há pouco = foi resetado agora: quanto mais recente, mais nota.
    RECENT = { 15.minutes => 4, 2.hours => 2 }.freeze
    # Respondendo agora: está funcionando, é pouco provável que seja o substituído.
    ALIVE = -3
    ALIVE_FOR = 1.hour
    SAME_MODEL = 3
    LIMIT = 6

    module_function

    def call(new_device, limit: LIMIT)
      battery_new = Pairing.mesh(new_device)["power"] == "battery" || battery?(new_device)
      Devices::Replace.candidates(new_device).includes(:points).filter_map { |old| item(old, new_device, battery_new) }
                      .sort_by { |i| [ -i.score, -(i.device.last_seen_at || Time.zone.at(0)).to_i, i.device.name ] }
                      .first(limit)
    end

    def item(old, new_device, battery_new)
      pairs = Devices::Replace.suggest(old, new_device)
      mapped = pairs.select(&:new)
      return if mapped.empty?

      reasons = []
      score = mapped.sum { |p| Devices::Replace.score(p.old, p.new) }
      reasons << I18n.t("pairing.suggest.points", n: mapped.size, total: pairs.size)
      score += battery(old, battery_new, reasons)
      score += state(mapped, reasons)
      score += silence(old, reasons)
      if old.model.present? && old.model == new_device.model
        score += SAME_MODEL
        reasons << I18n.t("pairing.suggest.same_model", model: old.model)
      end
      Item.new(device: old, score: score, reasons: reasons, mapped: mapped.size, total: pairs.size)
    end

    def battery?(device)
      device.battery_point_id.present? ||
        device.points.any? { |p| p.device_class.to_s.casecmp?("battery") || Devices::Replace.property(p) == "battery" }
    end

    def battery(old, battery_new, reasons)
      had = battery?(old)
      return -BATTERY if had != battery_new
      return 0 unless had

      reasons << I18n.t("pairing.suggest.battery")
      BATTERY
    end

    def state(mapped, reasons)
      same = mapped.select do |p|
        p.old.bool? && !p.old.value.nil? && p.new.reported_at.present? && !p.new.value.nil? &&
          Points::Decode.flip(p.new.value, p.invert) == p.old.value
      end
      return 0 if same.empty?

      reasons << I18n.t("pairing.suggest.state", names: same.map { |p| p.old.name }.join(", "))
      same.size * STATE
    end

    def silence(old, reasons)
      silent = old.status == "offline" || old.points.any? { |p| p.quality == "unavailable" }
      seen = old.last_seen_at
      return (seen && seen > ALIVE_FOR.ago ? ALIVE : 0) unless silent

      reasons << (seen ? I18n.t("pairing.suggest.silent_since", ago: ApplicationController.helpers.time_ago_in_words(seen)) : I18n.t("pairing.suggest.silent"))
      SILENT + (seen ? RECENT.find { |span, _| seen > span.ago }&.last.to_i : 0)
    end
  end
end
