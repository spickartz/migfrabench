require 'yaml'

module Migfrabench
  # the CLI
  class Migrator 
    def initialize(hostname='devon', config_file, rounds)
      @config_yaml = YAML.load_file(config_file)

#      @mqtt_client = MQTT::Client.connect(hostname)

      create_migfra_tasks(@config_yaml)
      if rounds.nil?
        @migration_rounds = @config_yaml['rounds'] 
      else
        @migration_rounds = rounds 
      end
    end

    def start
#      @mqtt_client.publish('mytopic', 'hello world')
      @start_tasks.each do |topic, message|
        puts topic
        puts message.to_yaml
        puts ""
      end
      @stop_tasks.each do |topic, message|
        puts topic
        puts message.to_yaml
        puts ""
      end
      
      @migration_tasks.each do |topic, message|
        puts topic
        puts message.to_yaml
        puts ""
      end

      puts "###########"
      puts @migration_rounds
      puts "###########"
    end

    private
    def create_migfra_tasks(config_yaml)
      # prepare task hashes
      @start_tasks={}
      @stop_tasks={}
      @migration_tasks = {}

      config_yaml['bench_config'].each do |vm|
        # request_topic
        request_topic = config_yaml['request_topic'].gsub(/<hostname>/, vm['source'])

        # extract start task
        @start_tasks[request_topic] ||= {} 
        @start_tasks[request_topic]['task'] ||= 'start vm'
        @start_tasks[request_topic]['vm-configurations'] ||= [] 
        @start_tasks[request_topic]['vm-configurations'] << vm['vm-configuration']

        # extract stop task
        @stop_tasks[request_topic] ||= {} 
        @stop_tasks[request_topic]['task'] ||= 'stop vm'
        @stop_tasks[request_topic]['vm-configurations'] ||= [] 
        @stop_tasks[request_topic]['vm-configurations'] << {'vm-name' => vm['vm-configuration']['vm-name']}
        
        # extract migrate task
        @migration_tasks[request_topic] ||= {} 
        @migration_tasks[request_topic]['task'] ||= 'migrate vm'
        @migration_tasks[request_topic]['vm-name'] = vm['vm-configuration']['vm-name']
        @migration_tasks[request_topic]['destination'] = vm['destination']
        @migration_tasks[request_topic]['parameter'] = {}
        @migration_tasks[request_topic]['parameter']['live-migration'] = vm['live-migration']
        @migration_tasks[request_topic]['parameter']['pscom-hook-procs'] = vm['procs-per-vm']
      end
    end
  end
end

