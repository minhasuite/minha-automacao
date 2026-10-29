module Api
  module V1
    # Base da API das primitivas de automação (F4), aninhadas no local e rasas
    # no resto (`/sites/:site_id/<recurso>`, `/<recurso>/:id`). Ver: qualquer
    # papel no local; criar, editar, excluir: técnico ou dono. O JSON é a linha
    # do banco (sem tenant_id).
    class AutomationController < BaseController
      class_attribute :model, :fields

      def index
        site = Site.find(params[:site_id])
        authorize_site!(site, :view)
        records, meta = paginate(model.where(site_id: site.id).order(:created_at))
        render_data(records.map { |r| serialize(r) }, meta: meta)
      end

      def show = render_data(serialize(find(:view)))

      def create
        site = Site.find(params[:site_id])
        authorize_site!(site, :manage)
        render_data(serialize(model.create!(params.permit(*fields).merge(site_id: site.id))), status: :created)
      end

      def update
        record = find(:manage)
        record.update!(params.permit(*fields))
        render_data(serialize(record))
      end

      def destroy
        find(:manage).destroy!
        head :no_content
      end

      private

      def find(action)
        record = model.find(params[:id])
        authorize_site!(record.site, action)
        record
      end

      def serialize(record) = record.as_json(except: "tenant_id")
    end
  end
end
