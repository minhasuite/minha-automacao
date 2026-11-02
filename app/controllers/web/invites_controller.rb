module Web
  # Convite por link (F8d). Público: `/convite/:token` abre o cadastro direto
  # nesta instalação (sem "empresa"); aceitar cria a conta, o papel no local
  # e queima o link. Logado: o dono cancela um convite pendente.
  class InvitesController < ApplicationController
    skip_before_action :require_login!, only: %i[show accept]
    before_action :require_owner!, only: :destroy
    before_action :load_invite, only: %i[show accept]
    layout "auth", only: %i[show accept]
    rate_limit to: 10, within: 1.minute, only: :accept, with: -> { redirect_to login_path, alert: I18n.t("flash.too_many") }

    def show; end

    def accept
      user = @invite.accept!(name: params[:name], email: params[:email], password: params[:password])
      sign_in!(user)
      redirect_to root_path, notice: t("flash.welcome")
    rescue ActiveRecord::RecordInvalid => e
      flash.now[:alert] = e.record.errors.full_messages.to_sentence
      render :show, status: :unprocessable_content
    end

    def destroy
      Invite.pending.find(params[:id]).update!(expires_at: Time.current)
      redirect_to people_path, notice: t("notices.invite_canceled")
    end

    private

    def load_invite
      @invite = Invite.find_valid(params[:token])
      return render(:invalid, status: :not_found) unless @invite

      set_current_tenant(@invite.tenant)
    end
  end
end
