module Web
  # "Falar na Alexa" do painel (widget `announce`): texto ou voz gravada numa
  # Echo ou em todas (Alexa::Talk). Responde JSON para o controller Stimulus.
  class TalksController < ApplicationController
    def create
      site = Site.find(params[:site_id])
      authorize_site!(site, :command)
      commands = Alexa::Talk.call(site, targets: params[:targets], text: params[:text], audio: params[:audio], source: "web",
                                        allow: ->(p) { authorize_site!(site, :command, risk: p.risk) })
      failed = commands.find { |c| c.status == "failed" }
      render json: { ok: failed.nil?, error: failed&.error }.compact, status: failed ? :unprocessable_content : :ok
    rescue Alexa::Talk::Error, Points::Command::Error => e
      render json: { ok: false, error: e.message }, status: :unprocessable_content
    rescue SiteMembership::Forbidden => e
      render json: { ok: false, error: e.message }, status: :forbidden
    end
  end
end
