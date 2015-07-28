# coding: utf-8
lib = File.expand_path('../lib', __FILE__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require 'migfrabench/version'

Gem::Specification.new do |spec|
  spec.name          = "migfrabench"
  spec.version       = Migfrabench::VERSION
  spec.authors       = ["Simon Pickartz"]
  spec.email         = ["spickartz@eonerc.rwth-aachen.de"]

  spec.summary       = %q{benchmarks the FaST Migration-Framework}
  spec.description   = %q{e.g., migrate multiple VMs back and forth}
  spec.homepage      = "http://github.com/fast-project/migrationbench"
  spec.license       = "MIT"

  spec.files         = `git ls-files -z`.split("\x0").reject { |f| f.match(%r{^(test|spec|features)/}) }
#  spec.bindir        = "exe"
  spec.executables   = ["migfrabench"]
  spec.require_paths = ["lib"]

  spec.add_dependency "thor"
  spec.add_dependency "colorize"
  spec.add_dependency "mqtt"
  spec.add_dependency "celluloid"
  spec.add_dependency "thread_safe"
  spec.add_dependency "net-ssh"

  spec.add_development_dependency "bundler", "~> 1.10"
  spec.add_development_dependency "rake", "~> 10.0"
end
