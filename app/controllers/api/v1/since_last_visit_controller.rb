module Api
  module V1
    # GET /since_last_visit?since=2026-11-26T18:00:00Z → { since, items: [{ key, value, label, tone }] }
    # (SinceLastVisit; o app guarda a última visita e mostra o SsSinceLastVisit no Início).
    class SinceLastVisitController < BaseController
      def show
        since = Time.zone.parse(params[:since].to_s)
        return render_error(:invalid, I18n.t("errors.messages.invalid"), status: :unprocessable_content) unless since

        render_data({ since: since, items: SinceLastVisit.call(user: current_user, since: since) })
      rescue ArgumentError
        render_error(:invalid, I18n.t("errors.messages.invalid"), status: :unprocessable_content)
      end
    end
  end
end
