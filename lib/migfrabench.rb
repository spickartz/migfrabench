require "migfrabench/version"
require "migfrabench/migrator"

require 'thor'
require 'colorize'
require 'rubygems'
require 'mqtt'


module Migfrabench
  # the CLI
  class CLI < Thor
    desc "migrate", "execute migration benchmark"
    def migrate
      Migrator.new('pandora3').start
    end
  end
end
