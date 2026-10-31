require "rails_helper"

RSpec.describe PointsChannel, type: :channel do
  let(:owner) { create(:user) }
  let(:tenant) { owner.tenant }
  let(:point) { within(tenant) { create(:point) } }

  def signed(record) = Turbo::StreamsChannel.signed_stream_name(record)

  it "assina o ponto de quem tem papel no local" do
    stub_connection current_user: owner
    subscribe(signed_stream_name: signed(point))
    expect(subscription).to be_confirmed
    expect(subscription).to have_stream_from(point.to_gid_param)
  end

  it "recusa outra empresa, membro sem papel no local, outro modelo e nome forjado" do
    stub_connection current_user: create(:user)
    subscribe(signed_stream_name: signed(point))
    expect(subscription).to be_rejected

    stub_connection current_user: create(:user, tenant: tenant, role: "member")
    subscribe(signed_stream_name: signed(point))
    expect(subscription).to be_rejected

    stub_connection current_user: owner
    subscribe(signed_stream_name: signed(point.site))
    expect(subscription).to be_rejected
    subscribe(signed_stream_name: "forjado")
    expect(subscription).to be_rejected
  end

  it "assina os pontos do local (dashboards) só com papel nele" do
    stub_connection current_user: owner
    subscribe(signed_stream_name: Turbo::StreamsChannel.signed_stream_name([ point.site, :points ]))
    expect(subscription).to be_confirmed

    stub_connection current_user: create(:user, tenant: tenant, role: "member")
    subscribe(signed_stream_name: Turbo::StreamsChannel.signed_stream_name([ point.site, :points ]))
    expect(subscription).to be_rejected
  end
end

RSpec.describe ApplicationCable::Connection, type: :channel do
  let(:user) { create(:user) }

  it "conecta com a sessão da web e recusa sem login ou com senha trocada" do
    connect "/cable", session: { user_id: user.id, pwd: user.password_digest.to_s.last(10) }
    expect(connection.current_user).to eq(user)
    expect { connect "/cable" }.to have_rejected_connection
    expect { connect "/cable", session: { user_id: user.id, pwd: "outra" } }.to have_rejected_connection
  end

  it "conecta o app (F7) com o access token da API e recusa token inválido, vencido ou de pessoa desativada" do
    _t, access, = ApiToken.issue(user)
    connect "/cable", params: { access_token: access }
    expect(connection.current_user).to eq(user)
    expect { connect "/cable", params: { access_token: "x" } }.to have_rejected_connection

    token, other, = ApiToken.issue(user)
    token.update!(access_expires_at: 1.minute.ago)
    expect { connect "/cable", params: { access_token: other } }.to have_rejected_connection

    user.update!(disabled_at: Time.current)
    expect { connect "/cable", params: { access_token: access } }.to have_rejected_connection
  end
end
