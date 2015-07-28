require 'yaml'
require 'celluloid'
require 'securerandom'
require 'thread_safe'
require 'celluloid/autostart'
require 'net/ssh'

USER='pickartz'

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
      @migration_rounds += 1 unless @migration_rounds.even?
      @period = @config_yaml['period']

      # create result hash
      @migration_times = ThreadSafe::Hash.new

      # create requester/receiver and condition variable
      @requester = Requester.new(@msg_broker, @migration_rounds, @period, @migration_times)
      @receiver = Receiver.new(@msg_broker, @config_yaml['response_topic'], @migration_times)

      # create TaskRunners
      @config_yaml['bench-config'].each do |bench|
        @task_runners ||= []
        @task_runners << TaskRunner.new(bench['application'], bench['vm-configuration']['vm-name']) if bench['application']
      end
    end

    def start
      # start the receiver
      @receiver.async.run

      # start the VMs TODO: wait for VMs to be started
      @start_tasks.each do |topic, message|
        @communicator.pub(message.to_yaml, topic)
      end

      # start the task runners
      @task_runners.each { |task_runner| task_runner.async.run }
    
      # start requester/receiver
      @requester.run(@migration_tasks)

      @requester.terminate
      @receiver.terminate
#      @task_runners.each { |task_runner| task_runner.terminate }

      # stop the VMs
      sleep @period # TODO: sleep according to the last results
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

      config_yaml['bench-config'].each do |vm|
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
        @migration_tasks[:forth] ||= {} 
        @migration_tasks[:back] ||= {} 
        migrate_topic ||= {}
        migrate_topic[:forth] = config_yaml['request_topic'].gsub(/<hostname>/, vm['source'])
        migrate_topic[:back] = config_yaml['request_topic'].gsub(/<hostname>/, vm['destination'])
        destination ||= {}
        destination[:forth] = vm['destination']
        destination[:back] = vm['source']

        [:forth, :back].each do |dir|
          @migration_tasks[dir][migrate_topic[dir]] ||= {} 
          @migration_tasks[dir][migrate_topic[dir]]['task'] ||= 'migrate vm'
          @migration_tasks[dir][migrate_topic[dir]]['id'] ||= ''
          @migration_tasks[dir][migrate_topic[dir]]['vm-name'] = vm['vm-configuration']['vm-name']
          @migration_tasks[dir][migrate_topic[dir]]['destination'] = destination[dir]
          @migration_tasks[dir][migrate_topic[dir]]['parameter'] = {}
          @migration_tasks[dir][migrate_topic[dir]]['parameter']['live-migration'] = vm['live-migration']
          @migration_tasks[dir][migrate_topic[dir]]['parameter']['pscom-hook-procs'] = vm['procs-per-vm']
        end
      end
    end

    class Worker
      include Celluloid
      include Celluloid::Notifications
      
      def initialize(msg_broker, migration_times)
        @communicator = Migfrabench::Communicator.new(msg_broker) unless msg_broker.nil?
        @work_done = Celluloid::Condition.new
        @migration_times = migration_times unless migration_times.nil?
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
        cur_dir, next_dir = :forth, :back
        timer = every(@period) do
         
          migration_tasks[cur_dir].each do |topic, message|
            message['id'] = SecureRandom.uuid
            @migration_times[message['id']] = ThreadSafe::Hash.new
            @migration_times[message['id']][:start] = Time.now
            @communicator.pub(message.to_yaml, topic)
          end
          cur_dir, next_dir = next_dir, cur_dir
           
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

    class TaskRunner < Worker
      def initialize(cmd, host)
        @cmd = cmd
        @host = host
        @done = false
        
        subscribe(:migration_done, :shutdown)
      end

      def run
        until @done do 
          Net::SSH.start(host, USER) { |session| puts session.exec!(@cmd) }
          sleep 0.01
        end
      end

      def shutdown(topic, message)
        @done = true
      end
    end
  end
end

