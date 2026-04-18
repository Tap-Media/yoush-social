# frozen_string_literal: true

require 'aws-sdk-core'
require 'aws-sigv4'
require 'json'
require 'net/http'
require 'redis'
require 'securerandom'
require 'uri'

module Mastodon
  class SidekiqQueueController
    def self.run!
      new.run!
    end

    def initialize(env: ENV, credentials_provider: Aws::CredentialProviderChain.new, redis: nil, time_source: -> { Time.now.to_f })
      @region = env.fetch('AWS_REGION')
      @workspace = env.fetch('SIDEKIQ_CONTROLLER_WORKSPACE')
      @cluster_name = env.fetch('SIDEKIQ_CONTROLLER_CLUSTER')
      @burst_service_name = env.fetch('SIDEKIQ_CONTROLLER_BURST_SERVICE')
      @metric_namespace = env.fetch('SIDEKIQ_CONTROLLER_METRIC_NAMESPACE')
      @worker_queue_names = env.fetch('SIDEKIQ_CONTROLLER_WORKER_QUEUES').split(',').reject(&:empty?)
      @scheduler_queue_name = env.fetch('SIDEKIQ_CONTROLLER_SCHEDULER_QUEUE')
      @depth_scale_in_threshold = Integer(env.fetch('SIDEKIQ_CONTROLLER_DEPTH_SCALE_IN_THRESHOLD'))
      @latency_scale_in_threshold = Float(env.fetch('SIDEKIQ_CONTROLLER_LATENCY_SCALE_IN_THRESHOLD_SECONDS'))
      @lock_key = env.fetch('SIDEKIQ_CONTROLLER_LOCK_KEY')
      @lock_ttl = Integer(env.fetch('SIDEKIQ_CONTROLLER_LOCK_TTL_SECONDS'))
      @credentials_provider = credentials_provider
      @redis = redis || Redis.new(url: redis_url(env))
      @time_source = time_source
      @lock_token = SecureRandom.uuid
      @lock_acquired = false
    end

    def run!
      @lock_acquired = acquire_lock
      return unless @lock_acquired

      worker_snapshot = queue_snapshot(@worker_queue_names)
      scheduler_snapshot = queue_snapshot([@scheduler_queue_name])
      publish_metrics(
        worker_snapshot: worker_snapshot,
        scheduler_snapshot: scheduler_snapshot
      )

      puts({
        worker_queue_depth: worker_snapshot[:depth],
        worker_queue_latency: worker_snapshot[:latency],
        scheduler_queue_depth: scheduler_snapshot[:depth],
        scheduler_queue_latency: scheduler_snapshot[:latency],
      }.to_json)
    ensure
      release_lock if @lock_acquired
    end

    private

    def redis_url(env)
      return env['REDIS_URL'] if env['REDIS_URL'] && !env['REDIS_URL'].empty?

      host = env.fetch('REDIS_HOST')
      port = Integer(env.fetch('REDIS_PORT', '6379'))
      db = Integer(env.fetch('REDIS_DB', '0'))

      "redis://#{host}:#{port}/#{db}"
    end

    def acquire_lock
      @redis.set(@lock_key, @lock_token, nx: true, ex: @lock_ttl)
    end

    def release_lock
      @redis.call(
        'EVAL',
        "if redis.call('get', KEYS[1]) == ARGV[1] then return redis.call('del', KEYS[1]) else return 0 end",
        1,
        @lock_key,
        @lock_token
      )
    end

    def queue_snapshot(queue_names)
      queue_keys = queue_names.map { |name| sidekiq_queue_key(name) }
      responses = @redis.pipelined do |pipeline|
        queue_keys.each do |queue_key|
          pipeline.llen(queue_key)
          pipeline.lindex(queue_key, -1)
        end
      end

      depth = 0
      latency = 0.0

      responses.each_slice(2) do |queue_depth, oldest_job_payload|
        depth += queue_depth.to_i
        latency = [latency, queue_latency(oldest_job_payload)].max
      end

      {
        depth: depth,
        latency: latency,
      }
    end

    def sidekiq_queue_key(name)
      "queue:#{name}"
    end

    def queue_latency(oldest_job_payload)
      return 0.0 if oldest_job_payload.nil? || oldest_job_payload.empty?

      enqueued_at = JSON.parse(oldest_job_payload)['enqueued_at']
      return 0.0 if enqueued_at.nil?

      [@time_source.call - enqueued_at.to_f, 0.0].max
    rescue JSON::ParserError, TypeError
      0.0
    end

    def publish_metrics(worker_snapshot:, scheduler_snapshot:)
      common_dimensions = {
        'Workspace' => @workspace,
        'ClusterName' => @cluster_name,
      }
      depth_scale_signal = [worker_snapshot[:depth] - @depth_scale_in_threshold, 0].max
      latency_scale_signal = [worker_snapshot[:latency] - @latency_scale_in_threshold, 0.0].max

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
            name: 'SidekiqWorkerQueueDepthScaleSignal',
            value: depth_scale_signal,
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
            name: 'SidekiqWorkerQueueLatencyScaleSignal',
            value: latency_scale_signal,
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
        ]
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
