# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Mastodon::SidekiqQueueController do
  let(:env) do
    {
      'AWS_REGION' => 'ap-southeast-1',
      'SIDEKIQ_CONTROLLER_WORKSPACE' => 'dev',
      'SIDEKIQ_CONTROLLER_CLUSTER' => 'dev-yoush-social-cluster',
      'SIDEKIQ_CONTROLLER_BURST_SERVICE' => 'yoush-social-sidekiq-burst',
      'SIDEKIQ_CONTROLLER_METRIC_NAMESPACE' => 'Yoush/Social',
      'SIDEKIQ_CONTROLLER_WORKER_QUEUES' => 'default,push',
      'SIDEKIQ_CONTROLLER_SCHEDULER_QUEUE' => 'scheduler',
      'SIDEKIQ_CONTROLLER_DEPTH_PER_TASK' => '25',
      'SIDEKIQ_CONTROLLER_DEPTH_SCALE_IN_THRESHOLD' => '5',
      'SIDEKIQ_CONTROLLER_LATENCY_PER_TASK_SECONDS' => '15',
      'SIDEKIQ_CONTROLLER_LATENCY_SCALE_IN_THRESHOLD_SECONDS' => '5',
      'SIDEKIQ_CONTROLLER_MAX_BURST_COUNT' => '4',
      'SIDEKIQ_CONTROLLER_LOCK_KEY' => 'lock-key',
      'SIDEKIQ_CONTROLLER_LOCK_TTL_SECONDS' => '55',
      'SIDEKIQ_CONTROLLER_MAX_STEP_CHANGE' => '1',
    }
  end

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

  describe '#signed_request' do
    it 'unwraps credential providers before building the signer' do
      credentials = instance_double(Aws::Credentials, access_key_id: 'key', secret_access_key: 'secret')
      ecs_credentials = instance_double(Aws::ECSCredentials, credentials: credentials)
      credentials_provider = instance_double(Aws::CredentialProviderChain, resolve: ecs_credentials)
      signer = instance_double(Aws::Sigv4::Signer)
      signature = instance_double(Aws::Sigv4::Signature, headers: { 'Authorization' => 'sig' })
      response = instance_double(Net::HTTPOK)
      http = instance_double(Net::HTTP)

      allow(Aws::Sigv4::Signer).to receive(:new).and_return(signer)
      allow(signer).to receive(:sign_request).and_return(signature)
      allow(response).to receive(:is_a?).with(Net::HTTPSuccess).and_return(true)
      allow(http).to receive(:request).and_return(response)
      allow(Net::HTTP).to receive(:start).and_yield(http)

      controller = described_class.new(env: env, credentials_provider: credentials_provider)

      controller.send(
        :signed_request,
        service: 'ecs',
        endpoint: URI('https://ecs.ap-southeast-1.amazonaws.com/'),
        headers: {
          'content-type' => 'application/x-amz-json-1.1',
          'host' => 'ecs.ap-southeast-1.amazonaws.com',
        },
        body: '{}'
      )

      expect(Aws::Sigv4::Signer).to have_received(:new).with(
        service: 'ecs',
        region: 'ap-southeast-1',
        credentials: credentials
      )
    end
  end
end
