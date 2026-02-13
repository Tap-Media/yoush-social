# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Memories', :inline_jobs do
  let(:user)    { Fabricate(:user) }
  let(:scopes)  { 'read:statuses' }
  let(:token)   { Fabricate(:accessible_access_token, resource_owner_id: user.id, scopes: scopes) }
  let(:headers) { { 'Authorization' => "Bearer #{token.token}" } }

  describe 'GET /api/v1/memories' do
    subject do
      get '/api/v1/memories', headers: headers, params: params
    end

    let(:params) { {} }

    it_behaves_like 'forbidden for wrong scope', 'write write:statuses'

    context 'when memories are disabled' do
      before do
        user.settings['memories_enabled'] = false
        user.save!
      end

      it 'returns http forbidden' do
        subject
        expect(response).to have_http_status(403)
      end
    end

    context 'when there are statuses on this day' do
      let!(:status_today) { Fabricate(:status, account: user.account, created_at: 1.year.ago) }
      let!(:status_yesterday) { Fabricate(:status, account: user.account, created_at: 1.year.ago - 1.day) }
      let!(:status_last_month) { Fabricate(:status, account: user.account, created_at: 1.month.ago) }

      it 'returns http success and statuses from previous years on this day' do
        subject

        expect(response).to have_http_status(200)
        expect(response.content_type)
          .to start_with('application/json')

        expect(response.parsed_body.pluck(:id)).to contain_exactly(status_today.id.to_s)
        expect(response.parsed_body.pluck(:id)).not_to include(status_yesterday.id.to_s)
        expect(response.parsed_body.pluck(:id)).not_to include(status_last_month.id.to_s)
      end

      context 'with limit param' do
        let(:params) { { limit: 1 } }
        let!(:status_today_2) { Fabricate(:status, account: user.account, created_at: 2.years.ago) }

        it 'returns only the requested number of statuses with pagination headers', :aggregate_failures do
          subject

          expect(response.parsed_body.size).to eq(params[:limit])

          expect(response)
            .to include_pagination_headers(
              prev: api_v1_memories_url(limit: params[:limit], min_id: status_today.id),
              next: api_v1_memories_url(limit: params[:limit], max_id: status_today.id)
            )
          expect(response.content_type)
            .to start_with('application/json')
        end

        it 'pagination works correctly (continuity)' do
          # First request (gets status_today, newest first)
          get '/api/v1/memories', headers: headers, params: { limit: 1 }
          expect(response.parsed_body.pluck(:id)).to contain_exactly(status_today.id.to_s)

          next_link = response.links['next']
          expect(next_link).to be_present

          # Second request
          get next_link, headers: headers
          expect(response.parsed_body.pluck(:id)).to contain_exactly(status_today_2.id.to_s)
        end
      end
    end

    context 'without an authorization header' do
      let(:headers) { {} }

      it 'returns http unauthorized' do
        subject

        expect(response).to have_http_status(401)
        expect(response.content_type)
          .to start_with('application/json')
      end
    end

    context 'without a user context' do
      let(:token) { Fabricate(:accessible_access_token, resource_owner_id: nil, scopes: scopes) }

      it 'returns http unauthorized' do
        subject

        expect(response).to have_http_status(401)
        expect(response.content_type)
          .to start_with('application/json')
      end
    end
  end
end
