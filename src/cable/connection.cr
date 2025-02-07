require "uuid"

module Cable
  abstract class Connection
    class UnathorizedConnectionException < Exception; end

    property internal_identifier : String = "0"
    property connection_identifier : String = ""

    getter token : String?
    getter? connection_rejected : Bool = false
    getter socket
    getter started_at : Time = Time.utc

    CHANNELS = {} of String => Hash(String, Cable::Channel)

    def identifier
      internal_identifier
    end

    macro identified_by(name)
      property {{name.id}} = ""

      private def internal_identifier
        @{{name.id}}
      end
    end

    macro owned_by(type_definition)
      property {{type_definition.var}} : {{type_definition.type}}?
    end

    def initialize(request : HTTP::Request, @socket : HTTP::WebSocket)
      @token = request.query_params.fetch(Cable.settings.token, nil)

      begin
        connect
        # gather connection_identifier after the connection has gathered the id from identified_by(field)
        self.connection_identifier = "#{internal_identifier}-#{UUID.random}"
      rescue e : UnathorizedConnectionException
        reject_connection!
        socket.close(HTTP::WebSocket::CloseCode::NormalClosure, "Farewell")
        Cable::Logger.info { ("An unauthorized connection attempt was rejected") }
      end
    end

    abstract def connect

    def reject_connection!
      @connection_rejected = true
    end

    def close
      return true unless Connection::CHANNELS.has_key?(connection_identifier)

      Connection::CHANNELS[connection_identifier].each do |identifier, channel|
        # the ordering here is important
        Connection::CHANNELS[connection_identifier].delete(identifier)
        channel.close
      rescue e : IO::Error
        Cable::Logger.error { "IO::Error Exception: #{e.message} -> #{self.class.name}#close" }
      end

      Connection::CHANNELS.delete(connection_identifier)
      Cable::Logger.info { "Terminating connection #{connection_identifier}" }

      socket.close
    end

    def reject_unauthorized_connection
      raise UnathorizedConnectionException.new
    end

    def receive(message)
      payload = Cable::Payload.new(message)

      return subscribe(payload) if payload.command == "subscribe"
      return unsubscribe(payload) if payload.command == "unsubscribe"
      return message(payload) if payload.command == "message"
    end

    def subscribe(payload : Cable::Payload)
      return if connection_requesting_duplicate_channel_subscription?(payload)

      channel = Cable::Channel::CHANNELS[payload.channel].new(
        connection: self,
        identifier: payload.identifier,
        params: payload.channel_params
      )
      Connection::CHANNELS[connection_identifier] ||= {} of String => Cable::Channel
      Connection::CHANNELS[connection_identifier][payload.identifier] = channel
      channel.subscribed

      if channel.subscription_rejected?
        reject(payload)
        return
      end

      if stream_identifier = channel.stream_identifier
        Cable.server.subscribe_channel(channel: channel, identifier: stream_identifier)
        Cable::Logger.info { "#{channel.class} is streaming from #{stream_identifier}" }
      end

      Cable::Logger.info { "#{payload.channel} is transmitting the subscription confirmation" }
      socket.send({type: Cable.message(:confirmation), identifier: payload.identifier}.to_json)

      channel.run_after_subscribed_callbacks unless channel.subscription_rejected?
    end

    # ensure we only allow subscribing to the same channel once from a connection
    def connection_requesting_duplicate_channel_subscription?(payload)
      return unless connection_key = Connection::CHANNELS.dig?(connection_identifier, payload.identifier)

      connection_key.class.to_s == payload.channel
    end

    def unsubscribe(payload : Cable::Payload)
      if channel = Connection::CHANNELS[connection_identifier].delete(payload.identifier)
        channel.close
        Cable::Logger.info { "#{payload.channel} is transmitting the unsubscribe confirmation" }
        socket.send({type: Cable.message(:unsubscribe), identifier: payload.identifier}.to_json)
      end
    end

    def reject(payload : Cable::Payload)
      if channel = Connection::CHANNELS[connection_identifier].delete(payload.identifier)
        channel.unsubscribed
        Cable::Logger.info { "#{channel.class.to_s} is transmitting the subscription rejection" }
        socket.send({type: Cable.message(:rejection), identifier: payload.identifier}.to_json)
      end
    end

    def message(payload : Cable::Payload)
      if channel = Connection::CHANNELS.dig?(connection_identifier, payload.identifier)
        if payload.action?
          Cable::Logger.info { "#{channel.class}#perform(\"#{payload.action}\", #{payload.data})" }
          channel.perform(payload.action, payload.data)
        else
          begin
            Cable::Logger.info { "#{channel.class}#receive(#{payload.data})" }
            channel.receive(payload.data)
          rescue e : TypeCastError
            Cable::Logger.error { "Exception: #{e.message} -> #{self.class.name}#message(payload) { #{payload.inspect} }" }
          end
        end
      end
    end

    def self.broadcast_to(channel : String, message : String)
      Cable.server.publish(channel, message)
    end
  end
end
