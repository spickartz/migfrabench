require 'yaml'
require 'celluloid'
require 'securerandom'
require 'thread_safe'
require 'celluloid/autostart'

module Migfrabench
  class Migrator 
    def initialize(config_file, rounds)
      # load config
      @config_yaml = YAML.load_file(config_file)

      @msg_broker = @config_yaml['mqtt_broker']
      @communicator = Migfrabench::Communicator.new(@msg_broker)

      # create tasks
      create_migfra_tasks(@config_yaml)
      if rounds.nil?
        @migration_rounds = @config_yaml['rounds'] 
      else
        @migration_rounds = rounds 
      end
      @period = @config_yaml['period']

      # create result hash
      @migration_times = ThreadSafe::Hash.new

      # create requester/receiver and condition variable
      @requester = Requester.new(@msg_broker, @migration_rounds, @period, @migration_times)
      @receiver = Receiver.new(@msg_broker, @config_yaml['response_topic'], @migration_times)
    end

    def start
      # start the VMs
      @start_tasks.each do |topic, message|
        @communicator.pub(message.to_yaml, topic)
      end

      # start requester/receiver
      @requester.async.run(@migration_tasks)
      @receiver.run

      @requester.terminate
      @receiver.terminate

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
        @migration_tasks[request_topic]['id'] ||= ''
        @migration_tasks[request_topic]['vm-name'] = vm['vm-configuration']['vm-name']
        @migration_tasks[request_topic]['destination'] = vm['destination']
        @migration_tasks[request_topic]['parameter'] = {}
        @migration_tasks[request_topic]['parameter']['live-migration'] = vm['live-migration']
        @migration_tasks[request_topic]['parameter']['pscom-hook-procs'] = vm['procs-per-vm']
      end
    end

    class Worker
      include Celluloid
      include Celluloid::Notifications
      
      def initialize(msg_broker, migration_times)
        @communicator = Migfrabench::Communicator.new(msg_broker)
        @work_done = Celluloid::Condition.new
        @migration_times = migration_times
      end
    end

    class Requester < Worker
      def initialize(msg_broker, rounds, period, migration_times)
        super(msg_broker, migration_times)

        @rounds = rounds
        @period = period
      end

      def run(migration_tasks)
        # start migration requests
        cur_rounds = 0
        timer = every(@period) do

          migration_tasks.each do |topic, message|
            message['id'] = SecureRandom.uuid
            @migration_times[message['id']] = ThreadSafe::Hash.new
            @migration_times[message['id']][:start] = Time.now
            @communicator.pub(message.to_yaml, topic)
          end
          
          @work_done.signal if (cur_rounds += 1) == @rounds 
        end

        # wait for work to be done and shutdown receiver
        @work_done.wait 
        timer.cancel
        publish(:migration_done, '')
        
        puts @migration_times
      end
    end

    class Receiver < Worker
      def initialize(msg_broker, topic, migration_times)
        super(msg_broker, migration_times)

        @communicator.sub(topic)
        @migration_done = false
        subscribe(:migration_done, :shutdown)
      end

      def run
        @timer = every(0.0001) do 
          topic, message =  @communicator.recv
          puts message unless message.class == NilClass
        end

        @work_done.wait
      end

      def shutdown(topic, message)
        @timer.cancel
        @work_done.signal
      end
    end
  end
end

