module Web
  # Primeira configuração (produto): segue a lista de passos de `Onboarding`;
  # cada passo (plugin) diz o que mostrar e como salvar. Sem ninguém na
  # instalação, o primeiro passo cria o dono; depois, só o dono entra aqui.
  class OnboardingController < ApplicationController
    skip_before_action :require_login!
    before_action :load_flow
    layout "onboarding"
    rate_limit to: 10, within: 1.minute, only: :update, with: -> { redirect_to onboarding_path, alert: t("flash.too_many") }

    def show
      @step = params[:step] ? Onboarding.step(params[:step]) : Onboarding.current(@ctx)
      redirect_to(onboarding_path) unless @step && @steps.include?(@step) && @step.ready?(@ctx)
    end

    def update
      @step = Onboarding.step(params[:step])
      return redirect_to(onboarding_path) unless @step && @steps.include?(@step) && @step.ready?(@ctx)

      user_before = @ctx.user
      result = @step.save(@ctx, params.fetch(:onboarding, ActionController::Parameters.new))
      if result.is_a?(String)
        flash.now[:alert] = result
        return render(:show, status: :unprocessable_content)
      end

      sign_in!(@ctx.user) if user_before.nil? && @ctx.user
      set_current_tenant(@ctx.tenant)
      return stay if result == :stay

      Onboarding.mark_done!(@ctx, @step)

      flash[:notice] = @ctx.notice if @ctx.notice
      next_step
    end

    # "Agora não": marca o passo e segue.
    def skip
      @step = Onboarding.step(params[:step])
      return redirect_to(onboarding_path) unless @step&.optional? && @step.ready?(@ctx)

      Onboarding.mark_done!(@ctx, @step)
      next_step
    end

    # Resultado da descoberta (turbo-frame que a tela pede ao abrir o passo).
    def discover
      return head(:not_found) unless @ctx.site

      @found = Onboarding::Discovery.call(@ctx.site)
      render partial: "web/onboarding/found", locals: { found: @found }
    end

    def finish
      return redirect_to(onboarding_path) unless @ctx.user

      Onboarding.finish!(@ctx.tenant)
      redirect_to root_path, notice: t("onboarding.finished")
    end

    private

    # Sem ninguém: só o passo de conta. Com sessão: só o dono, e só enquanto não concluiu.
    def load_flow
      user = current_user
      if user.nil?
        return redirect_to(login_path) unless Onboarding.fresh_install?
      elsif !user.owner?
        return redirect_to(root_path)
      else
        Current.user = user
      end
      @ctx = Onboarding.context(user, base_url: request.base_url)
      @steps = Onboarding.steps_for(@ctx)
    end

    # Mesmo passo: com dado só desta resposta (link de convite) desenha aqui; senão volta com o aviso.
    def stay
      return render(:show) if @ctx.data.present?

      redirect_to onboarding_step_path(@step.key), notice: @ctx.notice
    end

    def next_step
      nxt = Onboarding.current(@ctx)
      return redirect_to(onboarding_step_path(nxt.key)) if nxt && !Onboarding.done?(@ctx, nxt.key)

      Onboarding.finish!(@ctx.tenant)
      redirect_to root_path, notice: t("onboarding.finished")
    end
  end
end
