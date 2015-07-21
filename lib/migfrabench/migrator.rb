module Migfrabench
  # the CLI
  class Migrator 
    def initialize(hostname)
      @mqtt_client = MQTT::Client.connect(hostname)
    end

    def start
      @mqtt_client.publish('mytopic', 'hello world')
    end
  end
end

