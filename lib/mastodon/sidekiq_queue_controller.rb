# frozen_string_literal: true

require 'aws-sdk-core'
require 'aws-sigv4'
require 'json'
require 'net/http'
require 'securerandom'
require 'sidekiq/api'
require 'uri'

module Mastodon
  class SidekiqQueueController
    def self.run!
      new.run!
    end

    def self.recommended_desired_count(depth:, depth_scale_in_threshold:, depth_per_task:, latency:, latency_scale_in_threshold:, latency_per_task:, max_burst_count:)
      desired_from_depth = if depth <= depth_scale_in_threshold
        0
      else
        ((depth - depth_scale_in_threshold).to_f / depth_per_task).ceil
      end

      desired_from_latency = if latency <= latency_scale_in_threshold
        0
      else
        (latency / latency_per_task).ceil
      end

      [[desired_from_depth, desired_from_latency].max, max_burst_count].min
    end

    def self.next_desired_count(current_desired:, recommended_desired:, max_step_change:)
      if recommended_desired > current_desired
        [current_desired + max_step_change, recommended_desired].min
      elsif recommended_desired < current_desired
        [current_desired - max_step_change, recommended_desired].max
      else
        current_desired
      end
    end

    def initialize(env: ENV, credentials_provider: Aws::CredentialProviderChain.new)
      @region = env.fetch('AWS_REGION')
      @workspace = env.fetch('SIDEKIQ_CONTROLLER_WORKSPACE')
      @cluster_name = env.fetch('SIDEKIQ_CONTROLLER_CLUSTER')
      @burst_service_name = env.fetch('SIDEKIQ_CONTROLLER_BURST_SERVICE')
      @metric_namespace = env.fetch('SIDEKIQ_CONTROLLER_METRIC_NAMESPACE')
      @worker_queue_names = env.fetch('SIDEKIQ_CONTROLLER_WORKER_QUEUES').split(',').reject(&:empty?)
      @scheduler_queue_name = env.fetch('SIDEKIQ_CONTROLLER_SCHEDULER_QUEUE')
      @depth_per_task = Integer(env.fetch('SIDEKIQ_CONTROLLER_DEPTH_PER_TASK'))
      @depth_scale_in_threshold = Integer(env.fetch('SIDEKIQ_CONTROLLER_DEPTH_SCALE_IN_THRESHOLD'))
      @latency_per_task = Float(env.fetch('SIDEKIQ_CONTROLLER_LATENCY_PER_TASK_SECONDS'))
      @latency_scale_in_threshold = Float(env.fetch('SIDEKIQ_CONTROLLER_LATENCY_SCALE_IN_THRESHOLD_SECONDS'))
      @max_burst_count = Integer(env.fetch('SIDEKIQ_CONTROLLER_MAX_BURST_COUNT'))
      @lock_key = env.fetch('SIDEKIQ_CONTROLLER_LOCK_KEY')
      @lock_ttl = Integer(env.fetch('SIDEKIQ_CONTROLLER_LOCK_TTL_SECONDS'))
      @max_step_change = Integer(env.fetch('SIDEKIQ_CONTROLLER_MAX_STEP_CHANGE'))
      @credentials_provider = credentials_provider
      @lock_token = SecureRandom.uuid
      @lock_acquired = false
    end

    def run!
      @lock_acquired = acquire_lock
      return unless @lock_acquired

      worker_snapshot = queue_snapshot(@worker_queue_names)
      scheduler_snapshot = queue_snapshot([@scheduler_queue_name])
      current_desired = current_desired_count
      recommended_desired = self.class.recommended_desired_count(
        depth: worker_snapshot[:depth],
        depth_scale_in_threshold: @depth_scale_in_threshold,
        depth_per_task: @depth_per_task,
        latency: worker_snapshot[:latency],
        latency_scale_in_threshold: @latency_scale_in_threshold,
        latency_per_task: @latency_per_task,
        max_burst_count: @max_burst_count
      )
      next_desired = self.class.next_desired_count(
        current_desired: current_desired,
        recommended_desired: recommended_desired,
        max_step_change: @max_step_change
      )

      update_desired_count(next_desired) if next_desired != current_desired
      publish_metrics(
        worker_snapshot: worker_snapshot,
        scheduler_snapshot: scheduler_snapshot,
        recommended_desired: recommended_desired,
        next_desired: next_desired
      )

      puts({
        worker_queue_depth: worker_snapshot[:depth],
        worker_queue_latency: worker_snapshot[:latency],
        scheduler_queue_depth: scheduler_snapshot[:depth],
        scheduler_queue_latency: scheduler_snapshot[:latency],
        burst_desired_current: current_desired,
        burst_desired_recommended: recommended_desired,
        burst_desired_applied: next_desired,
      }.to_json)
    ensure
      release_lock if @lock_acquired
    end

    private

    def acquire_lock
      Sidekiq.redis do |redis|
        redis.set(@lock_key, @lock_token, nx: true, ex: @lock_ttl)
      end
    end

    def release_lock
      Sidekiq.redis do |redis|
        redis.call(
          'EVAL',
          "if redis.call('get', KEYS[1]) == ARGV[1] then return redis.call('del', KEYS[1]) else return 0 end",
          1,
          @lock_key,
          @lock_token
        )
      end
    end

    def queue_snapshot(queue_names)
      queues = queue_names.map { |name| Sidekiq::Queue.new(name) }

      {
        depth: queues.sum(&:size),
        latency: queues.map(&:latency).max.to_f,
      }
    end

    def current_desired_count
      service = ecs_request(
        action: 'DescribeServices',
        payload: {
          cluster: @cluster_name,
          services: [@burst_service_name],
        }
      ).fetch('services').first

      raise 'Sidekiq burst ECS service was not returned by DescribeServices' if service.nil?

      service.fetch('desiredCount')
    end

    def update_desired_count(next_desired)
      ecs_request(
        action: 'UpdateService',
        payload: {
          cluster: @cluster_name,
          service: @burst_service_name,
          desiredCount: next_desired,
        }
      )
    end

    def publish_metrics(worker_snapshot:, scheduler_snapshot:, recommended_desired:, next_desired:)
      common_dimensions = {
        'Workspace' => @workspace,
        'ClusterName' => @cluster_name,
      }

      put_metric_data(
        namespace: @metric_namespace,
        metrics: [
          {
            name: 'SidekiqQueueControllerHeartbeat',
            value: 1,
            unit: 'Count',
            dimensions: common_dimensions,
          },
          {
            name: 'SidekiqWorkerQueueDepth',
            value: worker_snapshot[:depth],
            unit: 'Count',
            dimensions: common_dimensions.merge('ServiceName' => @burst_service_name),
          },
          {
            name: 'SidekiqWorkerQueueLatency',
            value: worker_snapshot[:latency],
            unit: 'Seconds',
            dimensions: common_dimensions.merge('ServiceName' => @burst_service_name),
          },
          {
            name: 'SidekiqSchedulerQueueDepth',
            value: scheduler_snapshot[:depth],
            unit: 'Count',
            dimensions: {
              'Workspace' => @workspace,
              'QueueName' => @scheduler_queue_name,
            },
          },
          {
            name: 'SidekiqSchedulerQueueLatency',
            value: scheduler_snapshot[:latency],
            unit: 'Seconds',
            dimensions: {
              'Workspace' => @workspace,
              'QueueName' => @scheduler_queue_name,
            },
          },
          {
            name: 'SidekiqBurstDesiredCountRecommended',
            value: recommended_desired,
            unit: 'Count',
            dimensions: common_dimensions.merge('ServiceName' => @burst_service_name),
          },
          {
            name: 'SidekiqBurstDesiredCountApplied',
            value: next_desired,
            unit: 'Count',
            dimensions: common_dimensions.merge('ServiceName' => @burst_service_name),
          },
        ]
      )
    end

    def ecs_request(action:, payload:)
      endpoint = URI("https://ecs.#{@region}.amazonaws.com/")
      headers = {
        'content-type' => 'application/x-amz-json-1.1',
        'host' => endpoint.host,
        'x-amz-target' => "AmazonEC2ContainerServiceV20141113.#{action}",
      }

      JSON.parse(
        signed_request(
          service: 'ecs',
          endpoint: endpoint,
          headers: headers,
          body: JSON.generate(payload)
        ).body
      )
    end

    def put_metric_data(namespace:, metrics:)
      endpoint = URI("https://monitoring.#{@region}.amazonaws.com/")
      params = {
        'Action' => 'PutMetricData',
        'Version' => '2010-08-01',
        'Namespace' => namespace,
      }

      metrics.each_with_index do |metric, metric_index|
        metric_member = metric_index + 1
        params["MetricData.member.#{metric_member}.MetricName"] = metric.fetch(:name)
        params["MetricData.member.#{metric_member}.Value"] = metric.fetch(:value).to_s
        params["MetricData.member.#{metric_member}.Unit"] = metric[:unit] if metric[:unit]

        metric.fetch(:dimensions).each_with_index do |(dimension_name, dimension_value), dimension_index|
          dimension_member = dimension_index + 1
          params["MetricData.member.#{metric_member}.Dimensions.member.#{dimension_member}.Name"] = dimension_name
          params["MetricData.member.#{metric_member}.Dimensions.member.#{dimension_member}.Value"] = dimension_value
        end
      end

      signed_request(
        service: 'monitoring',
        endpoint: endpoint,
        headers: {
          'content-type' => 'application/x-www-form-urlencoded; charset=utf-8',
          'host' => endpoint.host,
        },
        body: URI.encode_www_form(params)
      )
    end

    def signed_request(service:, endpoint:, headers:, body:)
      credentials = @credentials_provider

      3.times do
        break if credentials.respond_to?(:access_key_id) && credentials.respond_to?(:secret_access_key)

        next_credentials = if credentials.respond_to?(:resolve)
          credentials.resolve
        elsif credentials.respond_to?(:credentials)
          credentials.credentials
        end

        break if next_credentials.nil? || next_credentials.equal?(credentials)

        credentials = next_credentials
      end

      signer = Aws::Sigv4::Signer.new(
        service: service,
        region: @region,
        credentials: credentials
      )
      signature = signer.sign_request(
        http_method: 'POST',
        url: endpoint.to_s,
        headers: headers,
        body: body
      )

      request = Net::HTTP::Post.new(endpoint)
      headers.each { |name, value| request[name] = value }
      signature.headers.each { |name, value| request[name] = value }
      request.body = body

      Net::HTTP.start(endpoint.host, endpoint.port, use_ssl: true) do |http|
        response = http.request(request)
        raise "#{service} request failed: #{response.code} #{response.body}" unless response.is_a?(Net::HTTPSuccess)

        response
      end
    end
  end
end
