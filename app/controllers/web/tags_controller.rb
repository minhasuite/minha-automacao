module Web
  # ondaA1 (A2; Configurações → Rótulos do HA): os rótulos da instalação com
  # cor, nome e onde são usados. Renomear junta com outro de mesmo nome.
  class TagsController < ApplicationController
    before_action -> { raise ActiveRecord::RecordNotFound unless current_user.admin? }

    def index
      @tags = Tag.order(:name).to_a
      @usage = Tagging.group(:tag_id, :taggable_type).count.each_with_object(Hash.new { |h, k| h[k] = {} }) { |((tag, type), n), h| h[tag][type] = n }
    end

    def update
      tag = Tag.find(params[:id])
      attrs = params.require(:tag).permit(:name, :color)
      attrs[:color] = nil unless attrs[:color].to_s.match?(/\A#\h{6}\z/)
      other = Tag.where.not(id: tag.id).find_by(name: attrs[:name].to_s.squish.downcase) if attrs[:name].present?
      if other
        Tagging.where(tag_id: tag.id).where.not(taggable_id: Tagging.where(tag_id: other.id).select(:taggable_id)).update_all(tag_id: other.id) # rubocop:disable Rails/SkipsModelValidations
        tag.destroy!
        return redirect_to(tags_path, notice: t("tags.flash.merged", name: other.name))
      end
      return redirect_to(tags_path, alert: tag.errors.full_messages.to_sentence) unless tag.update(attrs)

      redirect_to tags_path, notice: t("tags.flash.saved")
    end

    def destroy
      Tag.find(params[:id]).destroy!
      redirect_to tags_path, notice: t("tags.flash.deleted")
    end
  end
end
