module Migfrabench
  class Communicator 
    def initialize(hostname='devon', port=1883)
#      @mqtt_client = MQTT::Client.connect(
#        host: hostname,
#        port: port,
#        ssl: false)
    end

    def sub(topic)
#      @mqtt_client.subscribe(topic)
    end

    def pub(message, topic)
#      @mqtt_client.publish(topic, message)
      puts message
    end

    def recv
#      client.get
    end
  end
end

