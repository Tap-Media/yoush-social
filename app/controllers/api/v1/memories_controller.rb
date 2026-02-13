# frozen_string_literal: true

class Api::V1::MemoriesController < Api::BaseController
  before_action -> { authorize_if_got_token! :read, :'read:statuses' }
  before_action :require_user!
  before_action :check_enabled
  after_action :insert_pagination_headers

  def index
    @statuses = load_statuses
    render json: @statuses, each_serializer: REST::StatusSerializer, relationships: StatusRelationshipsPresenter.new(@statuses, current_user&.account_id)
  end

  private

  def load_statuses
    cached_memories
  end

  def cached_memories
    preload_collection_paginated_by_id(
      memories_scope,
      Status,
      limit_param(DEFAULT_STATUSES_LIMIT),
      params_slice(:max_id, :since_id, :min_id)
    )
  end

  def memories_scope
    current_account.statuses.memories(current_user.time_zone)
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

  def check_enabled
    forbidden unless current_user.setting_memories_enabled
  end
end
