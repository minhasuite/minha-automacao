module Web
  # Painel do convidado (ideia 11): `/convidado/:token`, sem conta e sem menu.
  # Mostra só os widgets marcados com `"guest": true` do painel do link,
  # resolvidos com o papel do link (`viewer` ou `guest`). Comando só de ponto de
  # um widget marcado, comando sem valor (`SIMPLE`), papel x risco do ponto e
  # nunca crítico; cada comando vira `Command` (source "guest") e AuditEvent
  # no link. Link vencido ou revogado = "link inválido".
  class GuestController < ApplicationController
    SIMPLE = %w[on off toggle press run pulse].freeze

    skip_before_action :require_login!
    before_action :load_link
    layout "guest"
    rate_limit to: 30, within: 1.minute, only: :command, with: -> { redirect_to guest_path(params[:token]), alert: I18n.t("flash.too_many") }

    def show
      @link.touch_use! if @link.last_used_at.nil? || @link.last_used_at < 1.minute.ago
      @cards, @points = guest_cards
    end

    def command
      _cards, points = guest_cards
      p = points[params[:point_id].to_s] or raise ActiveRecord::RecordNotFound
      point = @link.site.points.find(p["id"])
      cmd = params[:command].to_s
      unless SIMPLE.include?(cmd) && Array(p["commands"]).include?(cmd) && point.risk != "critical" &&
             SiteMembership.allowed?(@link.role, :command, risk: point.risk) && p["can_command"]
        return redirect_to(guest_path(params[:token]), alert: t("guest.not_allowed"), status: :see_other)
      end

      c = Points::Command.call(point, cmd, nil, source: "guest", user: nil)
      @link.audit!("command", { "point_id" => point.id, "command" => cmd, "command_id" => c.id })
      redirect_to guest_path(params[:token]), status: :see_other, **(c.error ? { alert: c.error } : {})
    rescue Points::Command::Error => e
      redirect_to guest_path(params[:token]), alert: e.message, status: :see_other
    end

    private

    def load_link
      @link = GuestLink.find_valid(params[:token])
      return render(:invalid, status: :not_found) unless @link

      set_current_tenant(@link.tenant)
    end

    # [cards [{title, icon, point_ids}], points {id → ponto}] dos widgets marcados, com o papel do link.
    def guest_cards
      resolved = Dashboards::Resolver.new(@link.dashboard, role: @link.role).call
      points = resolved["points"]
      cards = Array(resolved["views"]).flat_map { |v| guest_widgets(Array(v["sections"]).flat_map { |s| Array(s["widgets"]) }) }
      cards = cards.filter_map do |w|
        ids = (Array(w.dig("data", "point_ids")).presence || [ w["bind"], *Array(w["binds"]) ].compact.filter_map { |ref| points.values.find { |p| p["id"] == ref || p["key"] == ref }&.dig("id") })
        ids = ids.select { |id| points[id] }
        { "title" => w["label"].presence || w.dig("data", "title") || points[ids.first]&.dig("title") || points[ids.first]&.dig("name"), "icon" => w["icon"], "point_ids" => ids } if ids.any?
      end
      allowed = cards.flat_map { |c| c["point_ids"] }.to_set
      [ cards, points.select { |id, _| allowed.include?(id) } ]
    end

    # Marcado = ele e o que está dentro (pilha); escondido pelo visible_if não entra.
    def guest_widgets(list)
      list.flat_map do |w|
        next [] if w["visible"] == false

        w["guest"] == true ? Dashboards::Resolver.flatten([ w ]) : guest_widgets(Array(w["widgets"]))
      end
    end
  end
end
