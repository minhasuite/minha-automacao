module Api
  module V1
    # Cadastro, login (e-mail/senha e Google), refresh e logout. Signup, login,
    # google e refresh rodam SEM tenant.
    class AuthController < BaseController
      PUBLIC = %i[signup login google refresh password_forgot password_reset].freeze
      FORGOT_PER_EMAIL_HOUR = 3
      skip_before_action :authenticate_request!, only: PUBLIC
      skip_before_action :set_tenant, only: PUBLIC

      # POST /auth/signup { name, email, password, company_name?, device_name? }
      def signup
        user = nil
        ActiveRecord::Base.transaction do
          tenant = Tenant.create!(name: params[:company_name].presence || "Empresa de #{params[:name].to_s.split.first || 'você'}")
          user = User.create!(tenant: tenant, name: params[:name], email: params[:email], password: params[:password].to_s)
        end
        issue(user, :created)
      end

      # POST /auth/login { email, password, device_name? }
      def login
        user = User.find_by(email: params[:email].to_s.strip.downcase)
        if user&.password_digest.present? && user.authenticate(params[:password].to_s)
          issue(user, :created)
        else
          BCrypt::Password.create("timing") unless user # iguala o tempo de resposta
          render_error(:invalid_credentials, "E-mail ou senha inválidos.", status: :unauthorized)
        end
      end

      # POST /auth/google { id_token, device_name? } — verifica o JWT contra o
      # client web (GOOGLE_CLIENT_ID). Cria a conta (e a empresa) na primeira vez.
      def google
        return render_error(:google_unconfigured, "Login Google indisponível.", status: :service_unavailable) if ENV["GOOGLE_CLIENT_ID"].blank?

        issue(User.from_google!(params[:id_token]), :created)
      rescue Google::Auth::IDTokens::VerificationError
        render_error(:invalid_token, "Token do Google inválido.", status: :unauthorized)
      end

      # POST /auth/refresh { refresh_token }
      def refresh
        presented = params[:refresh_token].to_s
        if (token = ApiToken.find_by_refresh(presented))
          access, refresh = token.rotate!
          return render_tokens(token, access, refresh)
        end
        if (compromised = ApiToken.reused(presented))
          compromised.revoke!
          return render_error(:token_reuse_detected, "Sessão revogada por segurança. Entre de novo.", status: :unauthorized)
        end
        render_error(:invalid_token, "Refresh token inválido ou expirado.", status: :unauthorized)
      end

      # POST /auth/password/forgot { email } — sempre 200 (não revela se a
      # conta existe). Sem SMTP configurado o e-mail não sai: só log.
      def password_forgot
        email = params.require(:email).to_s.strip.downcase
        user = User.find_by(email: email)
        if user && !forgot_throttled?(email)
          if ApplicationMailer.deliverable?
            PasswordMailer.reset(user, user.generate_token_for(:password_recovery)).deliver_later
          else
            Rails.logger.warn("[auth] redefinição de senha pedida (user=#{user.id}), mas SMTP não está configurado: e-mail não enviado")
          end
        end
        render_data({ sent: true })
      end

      # POST /auth/password/reset { token, password } — troca a senha e
      # derruba todas as sessões.
      def password_reset
        user = User.find_by_token_for(:password_recovery, params.require(:token).to_s)
        return render_error(:invalid_token, "Link de redefinição inválido ou expirado.", status: :unprocessable_content) unless user

        User.transaction do
          user.update!(password: params.require(:password).to_s)
          user.api_tokens.active.update_all(revoked_at: Time.current) # rubocop:disable Rails/SkipsModelValidations
        end
        render_data({ reset: true })
      end

      # DELETE /auth/logout
      def logout
        @current_api_token&.revoke!
        head :no_content
      end

      private

      def forgot_throttled?(email)
        count = Rails.cache.increment("password_forgot/#{Digest::SHA256.hexdigest(email)}", 1, expires_in: 1.hour)
        count.to_i > FORGOT_PER_EMAIL_HOUR
      end

      def issue(user, status)
        token, access, refresh = ApiToken.issue(user, device_name: params[:device_name])
        render_tokens(token, access, refresh, status: status)
      end

      def render_tokens(token, access, refresh, status: :ok)
        render_data({ access_token: access, refresh_token: refresh, token_type: "Bearer",
                      access_expires_at: token.access_expires_at, refresh_expires_at: token.refresh_expires_at,
                      user: UserSerializer.new(token.user).to_h }, status: status)
      end
    end
  end
end
