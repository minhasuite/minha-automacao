require "rails_helper"

RSpec.describe ExecuteCommandJob do
  it "sai da fila antes dos outros jobs (prioridade menor no Solid Queue)" do
    expect(described_class.new.priority).to eq(-10)
    expect(PollDeviceJob.new.priority.to_i).to be > described_class.new.priority
  end
end
