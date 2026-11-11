module Api
  module V1
    # Intenções personalizadas da voz (P3, `AssistCustomIntent`): frase → cena
    # ou script, por local e idioma. Ver: qualquer papel; cadastrar: técnico ou dono.
    # Alvo em `target` ("scene:<id>" ou "script:<id do ponto>"); `sentences` é lista.
    class AssistCustomIntentsController < AutomationController
      self.model = AssistCustomIntent
      self.fields = [ :name, :language, :target, :response, :enabled, { sentences: [] } ]

      private

      def serialize(record) = super.merge("target" => record.target)
    end
  end
end
