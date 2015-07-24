module Migfrabench
  class Communicator 
    def initialize(msg_broker='localhost', port=1883)
      @mqtt_client = MQTT::Client.connect(msg_broker)
    end

    def sub(topic)
      @mqtt_client.subscribe(topic)
    end

    def pub(message, topic)
      @mqtt_client.publish(topic, message)
    end

    def recv
      @mqtt_client.get unless @mqtt_client.queue_empty?
    end
  end
end

