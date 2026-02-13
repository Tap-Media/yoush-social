# frozen_string_literal: true

class Api::V1::MemoriesController < Api::BaseController
  before_action -> { authorize_if_got_token! :read, :'read:statuses' }
  before_action :require_user!
  after_action :insert_pagination_headers

  def index
    @statuses = load_statuses
    render json: @statuses, each_serializer: REST::StatusSerializer, relationships: StatusRelationshipsPresenter.new(@statuses, current_user&.account_id)
  end

  private

  def load_statuses
    current_account.statuses.on_this_day(current_user.time_zone).order(created_at: :desc).page(params[:page]).per(limit_param(DEFAULT_STATUSES_LIMIT))
  end

  def next_path
    api_v1_memories_url(pagination_params(max_id: pagination_max_id)) if records_continue?
  end

  def prev_path
    api_v1_memories_url(pagination_params(min_id: pagination_since_id)) unless @statuses.empty?
  end

  def pagination_collection
    @statuses
  end

  def records_continue?
    @statuses.size == limit_param(DEFAULT_STATUSES_LIMIT)
  end
end
