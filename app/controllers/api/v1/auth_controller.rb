module Api
  module V1
    # Cadastro, login (e-mail/senha e Google), refresh e logout. Signup, login,
    # google e refresh rodam SEM tenant.
    class AuthController < BaseController
      PUBLIC = %i[signup login providers google refresh password_forgot password_reset passkey_options passkey].freeze
      FORGOT_PER_EMAIL_HOUR = 3
      skip_before_action :authenticate_request!, only: PUBLIC
      skip_before_action :set_tenant, only: PUBLIC

      # POST /auth/signup { name, email, password, device_name? } — cria uma instalação nova.
      def signup
        user = nil
        ActiveRecord::Base.transaction do
          tenant = Tenant.create!(name: "Casa de #{params[:name].to_s.split.first || 'você'}")
          user = User.create!(tenant: tenant, name: params[:name], email: params[:email], password: params[:password].to_s)
        end
        issue(user, :created)
      end

      # POST /auth/login { email, password, otp?, device_name? } — com duas etapas
      # ligada, sem `otp` responde 401 mfa_required (o app pede o código e repete).
      def login
        user = User.find_by(email: params[:email].to_s.strip.downcase)
        if user&.password_digest.present? && !user.disabled? && user.authenticate(params[:password].to_s)
          return if mfa_refused?(user)

          issue(user, :created)
        else
          BCrypt::Password.create("timing") unless user # iguala o tempo de resposta
          render_error(:invalid_credentials, "E-mail ou senha inválidos.", status: :unauthorized)
        end
      end

      # GET /auth/providers — o que este servidor aceita no login. O app usa o
      # `google_client_id` (client web) como serverClientId do google_sign_in:
      # cada instalação diz o seu; nulo = sem botão do Google.
      def providers
        render_data({ google_client_id: GoogleLogin.client_id })
      end

      # POST /auth/google { id_token, otp?, invite_token?, device_name? } — o
      # id_token do Google (GoogleLogin: assinatura, audiência, e-mail
      # verificado). Acha/vincula a conta pelo e-mail ou cria (no convite, se
      # vier; senão uma instalação nova). Duas etapas: como no login, sem
      # `otp` responde 401 mfa_required e o app repete com o código.
      def google
        return render_error(:google_unconfigured, "Login Google indisponível.", status: :service_unavailable) unless GoogleLogin.enabled?

        user = User.from_google!(params[:id_token], invite: Invite.find_valid(params[:invite_token]))
        return render_error(:account_disabled, "Esta conta está desativada.", status: :forbidden) if user.disabled?
        return if mfa_refused?(user)

        issue(user, :created)
      rescue GoogleLogin::Error
        render_error(:invalid_token, "Token do Google inválido.", status: :unauthorized)
      end

      # POST /auth/refresh { refresh_token }
      def refresh
        presented = params[:refresh_token].to_s
        if (token = ApiToken.find_by_refresh(presented)) && !token.user.disabled?
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

      # appweb2: entrar com passkey pelo Credential Manager do Android.
      # POST /auth/passkey/options → {challenge_id, options} (o JSON do WebAuthn, vale 2 min)
      # POST /auth/passkey {challenge_id, credential: {id, response: {clientDataJSON, authenticatorData, signature}}}
      def passkey_options
        id = SecureRandom.hex(16)
        challenge = Passkeys.challenge
        Rails.cache.write("api_passkey_login/#{id}", challenge, expires_in: 2.minutes)
        render_data({ challenge_id: id, options: Passkeys.request_options(rp_id: request.host, challenge: challenge) })
      end

      def passkey
        challenge = Rails.cache.read("api_passkey_login/#{params[:challenge_id]}")
        Rails.cache.delete("api_passkey_login/#{params[:challenge_id]}")
        key = Passkeys.authenticate!(Passkeys.from_credential(params[:credential]), challenge: challenge, origin: Passkeys.android_origins, rp_id: request.host)
        return render_error(:account_disabled, "Esta conta está desativada.", status: :forbidden) if key.user.disabled?

        issue(key.user, :created)
      rescue Passkeys::Error
        render_error(:invalid_credentials, I18n.t("security.passkeys.failed"), status: :unauthorized)
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

      def mfa_refused?(user)
        return false unless Mfa.required?(user)
        return false if params[:otp].present? && Mfa.verify(user, params[:otp])

        params[:otp].blank? ? render_error(:mfa_required, "Informe o código de verificação.", status: :unauthorized) : render_error(:invalid_otp, "Código de verificação inválido.", status: :unauthorized)
        true
      end

      def issue(user, status)
        token, access, refresh = ApiToken.issue(user, device_name: params[:device_name])
        AuditEvent.login!(user, "app")
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
