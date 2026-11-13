module Notifications
  # Juntar avisos seguidos do mesmo assunto (docs/push.md, "Menos ruído"):
  # quem cria o aviso põe no `data` a chave (`merge_key`: "point:<id>",
  # "automation:<id>" ou a tag), a janela (`merge_s`) e o assunto
  # (`merge_subject`, ex.: o nome do ponto). Aviso com a mesma chave para a
  # mesma pessoa dentro da janela (contada do último) atualiza o existente:
  # título = assunto, corpo = "aberto às 19:15 e fechado às 19:17", volta a
  # não lido e o push sai com a mesma tag (substitui no aparelho, sem tocar de
  # novo). Crítico, aviso com botões ou progresso nunca se junta.
  module Merge
    MAX_ENTRIES = 20
    CLOCK = /\b([01]?\d|2[0-3])[:h][0-5]\d\b/

    module_function

    def key(data) = data["merge_key"].presence
    def window(data) = data["merge_s"].to_i

    def mergeable?(data)
      key(data) && window(data).positive? && data["priority"] != "critical" && data["actions"].blank? && data["progress"].nil? && data["clear"].blank?
    end

    # Prepara o primeiro aviso do grupo (registro das entradas + tag própria).
    def prepare(title, data, now = Time.current)
      return data unless mergeable?(data)

      data.merge("tag" => data["tag"].presence || "grupo:#{key(data)}", "entries" => [ { "title" => title.to_s, "at" => now.iso8601 } ])
    end

    # → a notificação atualizada ou nil (não tinha com quem juntar).
    def into(user, title, body, data, now = Time.current)
      return unless mergeable?(data)

      last = Notification.where(user_id: user&.id).where("notifications.data->>'merge_key' = ?", key(data))
                         .where(responded_at: nil).where(updated_at: (now - window(data))..).order(updated_at: :desc).first
      return unless last

      entries = Array(last.data["entries"])
      return if entries.size >= MAX_ENTRIES
      return if (at = Time.zone.parse(entries.last&.dig("at").to_s)) && at < now - window(data)

      entries += [ { "title" => title.to_s, "at" => now.iso8601 } ]
      merged = last.data.merge(data.except("entries")).merge("entries" => entries, "tag" => last.data["tag"], "merged" => true)
      subject = merged["merge_subject"].presence || entries.first["title"]
      zone = Notifications.zone(last.tenant, merged["site_id"])
      last.update!(title: subject.to_s.truncate(200), body: summary(entries, subject, zone, body).truncate(1000), data: merged,
                   read_at: nil, created_at: now)
      last
    end

    # "aberto às 19:15 e fechado às 19:17": título de cada um sem o assunto e com a hora.
    def summary(entries, subject, zone, last_body = nil)
      parts = entries.map do |e|
        text = e["title"].to_s.sub(/\A#{Regexp.escape(subject.to_s)}\s*[:\-–·]?\s*/i, "").strip
        text = e["title"].to_s if text.blank?
        at = Time.zone.parse(e["at"].to_s)&.in_time_zone(zone)
        text.match?(CLOCK) || at.nil? ? text : I18n.t("notifications.merge.at", what: text, time: at.strftime("%H:%M"))
      end
      sentence = parts.to_sentence(words_connector: ", ", two_words_connector: I18n.t("notifications.merge.and"),
                                   last_word_connector: I18n.t("notifications.merge.and"))
      [ sentence.upcase_first, last_body.presence ].compact.join(". ")
    end
  end
end
