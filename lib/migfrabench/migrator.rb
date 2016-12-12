require 'yaml'
require 'celluloid'
require 'securerandom'
require 'thread_safe'
require 'celluloid/autostart'
require 'net/ssh'
require 'terminal-table'
require 'ruby-progressbar'
require 'fileutils'

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
      @start_stop_vms = @config_yaml['start-stop-vms']
      @evaluate = @config_yaml['evaluate']

      # create result hash
      @migration_times = ThreadSafe::Hash.new

      # create requester/receiver and condition variable
      @requester = Requester.new(@msg_broker, @migration_rounds, @period, @migration_times)
      @receiver = Receiver.new(@msg_broker, @config_yaml['response_topic'], @migration_times)

      # crate log-dir
      @log_dir = @config_yaml['log-dir']
      FileUtils.mkdir_p(@log_dir) unless @log_dir.nil?

      # create TaskRunners
      @config_yaml['bench-config'].each do |bench|
        @init_task_runners ||= []
        @init_task_runners << TaskRunner.new(bench['init-app'], bench['vm-configuration']['vm-name'], @log_dir, true) if bench['init-app']
        @task_runners ||= []
        @task_runners << TaskRunner.new(bench['app'], bench['vm-configuration']['vm-name'], @log_dir, false) if bench['app']
      end
    end

    def start
      # start the receiver
      @receiver.async.run

      # start the VMs TODO: wait for VMs to be started
      if @start_stop_vms
        @start_tasks.each do |topic, message|
          message['id'] = SecureRandom.uuid
          @migration_times[message['id']] = ThreadSafe::Hash.new
          @migration_times[message['id']][:start] = (Time.now.to_f*1000).to_i
          @communicator.pub(message.to_yaml, topic)
        end
        CountDown.new(20, "VM boot").run
      end

      # start initialization tasks and wait a bit
      init_futures = []
      @init_task_runners.each { |init_task_runner, index| init_futures << init_task_runner.future.run }
      init_futures.each { |future| future.value }
      CountDown.new(5, "Postpone task start").run

      # start the task runners
      @task_runners.each { |task_runner| task_runner.async.run }
      sleep 3

      # start requester/receiver
      @requester.run(@migration_tasks) unless @migration_tasks[:forth].nil?

      @requester.terminate
      @receiver.terminate
      @task_runners.each { |task_runner| task_runner.terminate }

      # stop the VMs
      if @start_stop_vms
        sleep @period # TODO: sleep according to the last results
        @stop_tasks.each do |topic, message|
          @communicator.pub(message.to_yaml, topic)
        end
      end

      # evaluate migration results
      puts create_table(eval_migration_times) if (@evaluate && !eval_migration_times.empty?)
    end

    private
    def create_table(evaluation)
      table_rows = []

      table = Terminal::Table.new do |table|
        tr_header = ['vm-name']
        evaluation[evaluation.keys[0]].sort.map { |figure, duration| tr_header << figure }

        table << tr_header
        evaluation.sort.map do |vm_name, results|
          cur_results = []
          cur_results << vm_name
          results.sort.map { |figure, duration| cur_results << (duration*1000).round(0) }
          table << cur_results
        end
      end

      table.style = {alignment: :right, border_x: "", border_i: "", border_y: ""}
      table
    end

    def eval_migration_times
      figures ||= {}
      @migration_times.each do |id, result|
        # read migfra results
        result_yaml = YAML.load(result[:msg])
        next unless result_yaml['result'].eql?('vm migrated')

        vm_name = result_yaml['vm-name']
        figures[vm_name] ||= {}
        figures[vm_name]['outer'] ||= 0
        figures[vm_name]['outer'] += result[:stop]-result[:start]

        result_yaml['time-measurement'].each do |figure, duration|
          figures[vm_name][figure] ||= 0
          figures[vm_name][figure] += duration
        end
      end

      figures.each do |vm_name, results|
        results.each { |figure, duration| figures[vm_name][figure] /= @migration_rounds }
      end
      figures
    end

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
        @start_tasks[request_topic]['vm-configuration'] ||= []
        @start_tasks[request_topic]['vm-configuration'] << vm['vm-configuration']
        @start_tasks[request_topic]['vm-configuration'].last['time-measurement'] = vm['time-measurement']

        # extract stop task
        @stop_tasks[request_topic] ||= {}
        @stop_tasks[request_topic]['task'] ||= 'stop vm'
        @stop_tasks[request_topic]['vm-configuration'] ||= []
        @stop_tasks[request_topic]['vm-configuration'] << {'vm-name' => vm['vm-configuration']['vm-name']}
        @stop_tasks[request_topic]['vm-configuration'].last['time-measurement'] = vm['time-measurement']

        # extract migrate task; skip if source == destination
        next if (vm['source'].eql?(vm['destination']))
        @migration_tasks[:forth] ||= {}
        @migration_tasks[:back] ||= {}
        migrate_topic ||= {}
        migrate_topic[:forth] = config_yaml['request_topic'].gsub(/<hostname>/, vm['source'])
        migrate_topic[:back] = config_yaml['request_topic'].gsub(/<hostname>/, vm['destination'])
        destination ||= {}
        destination[:forth] = vm['destination']
        destination[:back] = vm['source']

        [:forth, :back].each do |dir|
          new_task ||= {}
          new_task['task'] ||= 'migrate vm'
          new_task['id'] ||= ''
          new_task['vm-name'] = vm['vm-configuration']['vm-name']
          new_task['destination'] = destination[dir]
          new_task['time-measurement'] = vm['time-measurement']
          new_task['parameter'] = {}
          new_task['parameter']['live-migration'] = vm['live-migration']
          new_task['parameter']['rdma-migration'] = vm['rdma-migration']
          new_task['parameter']['pscom-hook-procs'] = vm['procs-per-vm']

          @migration_tasks[dir][migrate_topic[dir]] ||= []
          @migration_tasks[dir][migrate_topic[dir]] << new_task
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
        # initialize local variables and progress bar
        cur_rounds = 1
        pb = ProgressBar.create(total: @rounds, title: 'Migration Rounds', format: '  %t: %B  %c/%C')

        # start first round immediatetly
        migration_round(migration_tasks, :forth)
        CountDown.new(@period, "Next migration in").async.run

        cur_dir, next_dir = :back, :forth
        timer = every(@period) do
          # send request
          migration_round(migration_tasks, cur_dir)
          cur_dir, next_dir = next_dir, cur_dir
          pb.increment
          puts ""

          if (cur_rounds += 1) == @rounds
            @work_done.signal
          else
            CountDown.new(@period, "Next migration in").async.run
          end
        end

        # wait for work to be done
        @work_done.wait
        timer.cancel

        # shutdown the receiver when shure that the migration should be done
        CountDown.new(30, "Wait for last migration").run
        publish(:migration_done, '')
      end

      private
      def migration_round(migration_tasks, cur_dir)
        migration_tasks[cur_dir].each do |topic, messages|
          messages.each do |message|
            message['id'] = SecureRandom.uuid
            @migration_times[message['id']] = ThreadSafe::Hash.new
            @migration_times[message['id']][:start] = (Time.now.to_f*1000).to_i
            @communicator.pub(message.to_yaml, topic)
            sleep 1
          end
        end
      end
    end

    class CountDown < Worker
      def initialize(time, title)
        @timer = time
        @title = title
      end

      def run
        pb = ProgressBar.create(total: @timer, title: @title, format: '  %t: %B  %c/%C s')
        (@timer-1).times do
          pb.increment
          sleep 1
        end
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
          unless (message.class == NilClass)
            msg_id = YAML.load(message)['id']

            @migration_times[msg_id][:stop] = (Time.now.to_f*1000).to_i
            @migration_times[msg_id][:msg] = message
          end
        end

        @work_done.wait
      end

      def shutdown(topic, message)
        @timer.cancel
        @work_done.signal
      end
    end

    class TaskRunner < Worker
      def initialize(cmd, host, log_dir, run_once)
        @cmd = cmd
        @host = host
        @done = false
        @log_dir = log_dir
        @run_once = run_once

        subscribe(:migration_done, :shutdown)
      end

      def run
        runtime = 0
        if @run_once
          runtime = execute("init")
        else
          executions = 0
          until @done do
            execute(executions)
            executions +=1
            sleep 1
          end
        end

        runtime
      end

      def shutdown(topic, message)
        @done = true
      end

      private
      def execute(execution)
        runtime = 0
        Net::SSH.start(@host, USER) do |session|
          runtime = (Time.now.to_f*1000).to_i
          output = session.exec!(@cmd)
          runtime = (Time.now.to_f*1000).to_i - runtime
          File.open("#{@log_dir}/#{@host}_output_#{execution}.dat", "wb") { |file| file.write(output)} unless @log_dir.nil?
          File.open("#{@log_dir}/#{@host}_runtime_#{execution}.dat", "wb") { |file| file.write(runtime)} unless @log_dir.nil?
        end

        # return runtime
        runtime
      end
    end
  end
end

