module Web
  # Configurações → Pessoas (F8d). Ver: administrador ou dono. Mudar: só o
  # dono. O dono adiciona criando a conta (e-mail e senha inicial) ou por link
  # de convite (InvitesController). Em cada pessoa: papel na instalação, papel
  # por local, ativar/desativar e remover. O dono não se desativa nem se remove.
  class PeopleController < ApplicationController
    before_action :require_admin!
    before_action :require_owner!, except: %i[index show]
    before_action :load_person, only: %i[show update destroy toggle sites]
    before_action :protect_owner!, only: %i[update destroy toggle]

    def index
      @people = current_user.tenant.users.order(:name).to_a
      @invites = Invite.pending.includes(:site).order(created_at: :desc).to_a
      @sites = Site.order(:name).to_a
    end

    # Opção (b): link de convite de uso único, 7 dias. Mostrado só nesta resposta.
    def invite
      p = params.fetch(:invite, {})
      site = Site.find_by(id: p[:site_id]) if p[:site_id].present?
      _invite, token = Invite.generate!(created_by: current_user, role: p[:role].presence_in(User::ROLES - %w[owner]) || "member",
                                        site: site, site_role: p[:site_role].presence)
      @invite_url = invite_link_url(token)
      index
      render :index
    end

    def show
      @sites = Site.order(:name).to_a
      @memberships = SiteMembership.where(user: @person).index_by(&:site_id)
    end

    # Opção (a): o dono cria a conta com e-mail e senha inicial.
    def create
      p = params.require(:person)
      person = User.transaction do
        user = current_user.tenant.users.create!(name: p[:name], email: p[:email], password: p[:password].to_s,
                                                 role: p[:role].presence_in(User::ROLES - %w[owner]) || "member")
        site = Site.find_by(id: p[:site_id]) if p[:site_id].present?
        SiteMembership.create!(site: site, user: user, role: p[:site_role]) if site && p[:site_role].present?
        user
      end
      redirect_to person_path(person), notice: t("notices.person_created", name: person.name)
    end

    def update
      @person.update!(role: params.require(:person)[:role].presence_in(User::ROLES - %w[owner]) || @person.role)
      redirect_to person_path(@person), notice: t("notices.role_updated")
    end

    # Papel por local: { roles: { site_id => papel | "" (sem acesso) } }.
    def sites
      roles = params.fetch(:roles, {})
      Site.where(id: roles.keys).find_each do |site|
        role = roles[site.id]
        membership = SiteMembership.find_by(site: site, user: @person)
        if role.blank?
          membership&.destroy!
        elsif membership
          membership.update!(role: role)
        else
          SiteMembership.create!(site: site, user: @person, role: role)
        end
      end
      redirect_to person_path(@person), notice: t("notices.sites_updated")
    end

    def toggle
      @person.disabled? ? @person.update!(disabled_at: nil) : @person.disable!
      redirect_to person_path(@person), notice: @person.disabled? ? "#{@person.name} foi desativada e não entra mais." : "#{@person.name} foi reativada."
    end

    def destroy
      @person.destroy!
      redirect_to people_path, notice: t("notices.person_removed", name: @person.name)
    end

    private

    def load_person = @person = current_user.tenant.users.find(params[:id])

    def require_admin!
      redirect_to root_path, alert: t("notices.people_admin_only") unless current_user.admin?
    end

    def protect_owner!
      redirect_to person_path(@person), alert: t("notices.owner_locked") if @person.owner? || @person == current_user
    end
  end
end
