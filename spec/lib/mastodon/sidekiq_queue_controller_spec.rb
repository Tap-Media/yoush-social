# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Mastodon::SidekiqQueueController do
  describe '.recommended_desired_count' do
    it 'returns zero when both signals are below the scale-in thresholds' do
      result = described_class.recommended_desired_count(
        depth: 5,
        depth_scale_in_threshold: 5,
        depth_per_task: 25,
        latency: 5.0,
        latency_scale_in_threshold: 5.0,
        latency_per_task: 15.0,
        max_burst_count: 4
      )

      expect(result).to eq(0)
    end

    it 'uses the larger of depth and latency recommendations and caps at the max' do
      result = described_class.recommended_desired_count(
        depth: 260,
        depth_scale_in_threshold: 10,
        depth_per_task: 50,
        latency: 200.0,
        latency_scale_in_threshold: 10.0,
        latency_per_task: 30.0,
        max_burst_count: 4
      )

      expect(result).to eq(4)
    end
  end

  describe '.next_desired_count' do
    it 'limits scale out to the configured step size' do
      result = described_class.next_desired_count(
        current_desired: 0,
        recommended_desired: 3,
        max_step_change: 1
      )

      expect(result).to eq(1)
    end

    it 'limits scale in to the configured step size' do
      result = described_class.next_desired_count(
        current_desired: 3,
        recommended_desired: 0,
        max_step_change: 1
      )

      expect(result).to eq(2)
    end
  end
end
