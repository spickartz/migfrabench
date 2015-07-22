require "migfrabench/version"
require "migfrabench/migrator"
require "migfrabench/communicator"

require 'thor'
require 'colorize'
require 'rubygems'
require 'mqtt'


module Migfrabench
  # the CLI
  class CLI < Thor
    desc "migrate CONFIG", "execute migration benchmark"
    method_option :rounds, :aliases => '-r', :type => :numeric, :required => false, :desc => "define migration rounds"
    def migrate(config)
      Migrator.new('pandora3', config, options[:rounds]).start
    end
  end
end
