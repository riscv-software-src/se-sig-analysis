#!/usr/bin/env ruby
# frozen_string_literal: true

require 'yaml'

$root = File.realpath(File.dirname(__FILE__))

$targets = YAML.load(File.read("#{$root}/targets.yml")).freeze

load "#{$root}/suites/aosp/tasks.rake"
load "#{$root}/suites/embench_iot/tasks.rake"
load "#{$root}/suites/speccpu2017/tasks.rake"
#load "#{$root}/suites/zephyr/tasks.rake"

namespace :build do
  desc 'Build all known workloads'
  task all: ['build:speccpu2017', 'build:aosp', 'build:embench_iot']

  desc 'Clean up from the build process'
  task all: ['clean:speccpu2017']
end
