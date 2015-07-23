require 'yaml'
require 'celluloid'

module Migfrabench
  class Migrator 
    def initialize(hostname='devon', config_file, rounds)
      @communicator = Migfrabench::Communicator.new(hostname)
      # load config
      @config_yaml = YAML.load_file(config_file)

      # create tasks
      create_migfra_tasks(@config_yaml)
      if rounds.nil?
        @migration_rounds = @config_yaml['rounds'] 
      else
        @migration_rounds = rounds 
      end
      @period = @config_yaml['period']
      @hostname = hostname

      # create requester/receiver
#      @requester = Receiver.new(hostname)
    end

    def start
      # start the VMs
      @start_tasks.each do |topic, message|
        @communicator.pub(message.to_yaml, topic)
      end

      Requester.new(@hostname, @migration_rounds, @period).run(@migration_tasks)

      # stop the VMs
      @stop_tasks.each do |topic, message|
        @communicator.pub(message.to_yaml, topic)
      end
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

    class Actor
      include Celluloid
      
      def initialize(hostname)
        @communicator = Migfrabench::Communicator.new(hostname)
      end
    end

    class Requester < Actor
      @@id ||= 0
      def initialize(hostname, rounds, period)
        super(hostname)

        @rounds = rounds
        @period = period
        @requests_processed = Celluloid::Condition.new

        @my_id = @@id
        @@id += 1
      end

      def run(migration_tasks)
        # start migration requests
        cur_rounds = 0
        every(@period) do

          migration_tasks.each do |topic, message|
            @communicator.pub(message.to_yaml, topic)
          end
          
          @requests_processed.signal if (cur_rounds += 1) == @rounds
        end
    
        @requests_processed.wait 
      end
    end
  end
end

