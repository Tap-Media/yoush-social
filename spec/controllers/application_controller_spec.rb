# frozen_string_literal: true

require 'rails_helper'

RSpec.describe ApplicationController do
  render_views

  controller do
    def success = head(200)
  end

  def stub_error_layout_vite_tags
    %i[
      vite_client_tag
      vite_react_refresh_tag
      vite_polyfills_tag
      vite_stylesheet_tag
      vite_typescript_tag
    ].each do |method_name|
      allow_any_instance_of(ActionView::Base).to receive(method_name).and_return(nil)
    end
  end

  def stub_single_user_mode(enabled:, account_exists:)
    allow(Rails.configuration.x).to receive(:single_user_mode).and_return(enabled)

    accounts_scope = instance_double(ActiveRecord::Relation, exists?: account_exists)
    allow(Account).to receive(:without_internal).and_return(accounts_scope)
  end

  def with_oidc_logout_env(overrides = {})
    ClimateControl.modify(
      {
        OMNIAUTH_ONLY: 'true',
        OIDC_CLIENT_ID: 'yoush-social-web',
        OIDC_IDP_LOGOUT_REDIRECT_URI: 'https://dev.yoush.social.tapofthink.com/',
        OIDC_ISSUER: 'https://dev.yoush.auth.tapofthink.com/realms/yoush',
        OIDC_END_SESSION_ENDPOINT: nil,
      }.merge(overrides)
    ) do
      yield
    end
  end

  def stub_oidc_enabled
    allow(Rails.configuration.x.omniauth).to receive(:oidc_enabled?).and_return(true)
  end

  context 'with a forgery' do
    before do
      ActionController::Base.allow_forgery_protection = true
      routes.draw { post 'success' => 'anonymous#success' }
      stub_error_layout_vite_tags
    end

    it 'responds with 422 and error page' do
      post 'success'

      expect(response)
        .to have_http_status(422)
    end
  end

  describe 'helper_method :current_account' do
    it 'returns nil if not signed in' do
      expect(controller.view_context.current_account).to be_nil
    end

    it 'returns account if signed in' do
      account = Fabricate(:account)
      sign_in(account.user)
      expect(controller.view_context.current_account).to eq account
    end
  end

  describe 'helper_method :single_user_mode?' do
    it 'returns false if it is in single_user_mode but there is no account' do
      stub_single_user_mode(enabled: true, account_exists: false)
      expect(controller.view_context.single_user_mode?).to be false
    end

    it 'returns false if there is an account but it is not in single_user_mode' do
      stub_single_user_mode(enabled: false, account_exists: true)
      expect(controller.view_context.single_user_mode?).to be false
    end

    it 'returns true if it is in single_user_mode and there is an account' do
      stub_single_user_mode(enabled: true, account_exists: true)
      expect(controller.view_context.single_user_mode?).to be true
    end
  end

  describe 'before_action :check_suspension' do
    before do
      routes.draw { get 'success' => 'anonymous#success' }
    end

    it 'does nothing if not signed in' do
      get 'success'
      expect(response).to have_http_status(200)
    end

    it 'does nothing if user who signed in is not suspended' do
      sign_in(Fabricate(:account, suspended: false).user)
      get 'success'
      expect(response).to have_http_status(200)
    end

    it 'redirects to account status page' do
      sign_in(Fabricate(:account, suspended: true).user)
      get 'success'
      expect(response).to redirect_to(edit_user_registration_path)
    end
  end

  describe 'raise_not_found' do
    it 'raises error' do
      controller.params[:unmatched_route] = 'unmatched'
      expect { controller.raise_not_found }.to raise_error(ActionController::RoutingError, 'No route matches unmatched')
    end
  end

  describe '#after_sign_out_path_for' do
    context 'when oidc-only logout is enabled' do
      around do |example|
        with_oidc_logout_env do
          example.run
        end
      end

      before do
        stub_oidc_enabled
      end

      it 'builds a provider logout url with client_id and post_logout_redirect_uri' do
        expect(controller.send(:after_sign_out_path_for, :user)).to eq(
          'https://dev.yoush.auth.tapofthink.com/realms/yoush/protocol/openid-connect/logout?client_id=yoush-social-web&post_logout_redirect_uri=https%3A%2F%2Fdev.yoush.social.tapofthink.com%2F'
        )
      end
    end

    context 'when oidc logout config is incomplete' do
      around do |example|
        with_oidc_logout_env(OIDC_IDP_LOGOUT_REDIRECT_URI: nil) do
          example.run
        end
      end

      before do
        stub_oidc_enabled
      end

      it 'falls back to the omniauth logout route' do
        expect(controller.send(:after_sign_out_path_for, :user)).to eq('/auth/auth/openid_connect/logout')
      end
    end
  end
end
