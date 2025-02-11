module Cable
  class Backend < Cable::BackendCore
    # connection management
    getter redis_subscribe : Redis::Connection = Redis::Connection.new(URI.parse(Cable.settings.url))
    getter redis_publish : Redis::Client = Redis::Client.new(URI.parse(Cable.settings.url))

    # connection management
    def subscribe_connection : Redis::Connection
      redis_subscribe
    end

    def publish_connection : Redis::Client
      redis_publish
    end

    def close_subscribe_connection
      return if redis_subscribe.nil?

      redis_subscribe.unsubscribe
      redis_subscribe.close
    end

    def close_publish_connection
      return if redis_publish.nil?

      redis_publish.close
    end

    # internal pub/sub
    def open_subscribe_connection(channel)
      return if redis_subscribe.nil?

      redis_subscribe.subscribe(channel) do |subscription|
        subscription.on_message do |channel, message|
          if channel == "_internal" && message == "ping"
            Cable::Logger.debug { "Cable::Server#subscribe -> PONG" }
          elsif channel == "_internal" && message == "debug"
            Cable.server.debug
          else
            Cable.server.fiber_channel.send({channel, message})
            Cable::Logger.debug { "Cable::Server#subscribe channel:#{channel} message:#{message}" }
          end
        end
      end
    end

    # external pub/sub
    def publish_message(stream_identifier : String, message : String)
      return if redis_subscribe.nil?

      redis_publish.publish(stream_identifier, message)
    end

    # channel management
    def subscribe(stream_identifier : String)
      return if redis_subscribe.nil?

      redis_subscribe.subscribe(stream_identifier)
      redis_subscribe.flush
    end

    def unsubscribe(stream_identifier : String)
      return if redis_subscribe.nil?

      redis_subscribe.unsubscribe(stream_identifier)
    end

    # ping/pong

    # since @server.redis_subscribe connection is called on a block loop
    # we basically cannot call ping outside of the block
    # instead, we just spin up another new redis connection
    # then publish a special channel/message broadcast
    # the @server.redis_subscribe picks up this special combination
    # and calls ping on the block loop for us
    def ping_redis_subscribe
      Cable.server.publish("_internal", "ping")
    end

    def ping_redis_publish
      result = redis_publish.run({"ping"})
      Cable::Logger.debug { "Cable::RedisPinger.ping_redis_publish -> #{result}" }
    end
  end
end
