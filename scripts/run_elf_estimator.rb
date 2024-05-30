#!/usr/bin/env -S sh -c 'singularity run "`dirname $0`"/../.singularity/image.sif bundle exec ruby "$0" "$@"'
# frozen_string_literal: true

# Author: Derek R. Hower
#
# Run the ELF estimator program over workloads / toolchains

require 'digest'
require 'optparse'
require 'yaml'

$root = File.realpath(File.dirname(File.dirname(__FILE__))).freeze
$targets = YAML.load(File.read("#{$root}/targets.yml")).freeze

ALL_SUITES = Dir.glob("#{$root}/suites/*").map { |f| File.basename(f).to_sym }.freeze
ALL_TARGETS = $targets.keys.freeze

# read the manifests
MANIFEST = Dir.glob("#{$root}/suites/*/manifest.yml").map do |f|
  YAML.load(File.read(f))
end.flatten.freeze

options = {
  dryrun: false,
  suites: ALL_SUITES,
  targets: ALL_TARGETS,
  tag: nil,
  force: false,
  estimator_opts: ''
}
OptionParser.new do |parser|
  parser.banner = 'Usage: $0 [options]'

  parser.on('-n', '--dry-run', 'Do not actually run') do
    options[:dryrun] = true
  end
  parser.on('-s', '--suite s1,s2,s3', Array, 'Comma-separated list of suites to analyze. If not given, analyzes all suites.') do |suites|
    suites.each do |s|
      raise "Unknown suite '#{s}'" unless File.directory?("#{$root}/suites/#{s}")
    end
    options[:suites] = suites.map(&:to_sym)
  end
  parser.on('-t', '--target t1,t2,t3', Array, 'Comma-separated list of targets to analyze. If not given, analyzes all targets.') do |targets|
    targets.each do |t|
      raise "Unknown target '#{t}'" unless ALL_TARGETS.any?(t.to_sym)
    end
    options[:targets] = targets.map(&:to_sym)
  end
  parser.on('--tag TAG_NAME', String, 'Tag this run with TAG_NAME') do |t|
    options[:tag] = t
  end
  parser.on('-f', '--force', 'Re-run, even if results already exist') do
    options[:force] = true
  end
  parser.on('-e', '--estimator_flags FLAGS', "Extra flags to pass on to rv_elf_estimator") do |f|
    options[:estimator_opts] = f
  end
  parser.on('-h', '--help', 'Print this help') do
    puts parser
    exit
  end

end.parse!

config_options = options.reject{ |k,v| [:force, :dryrun].any?(k) }
options[:tag] ||= Digest::MD5.hexdigest config_options.to_s

output_dir = "#{$root}/runs/#{options[:tag]}"
unless options[:dryrun]
  if File.exist?(output_dir)
    unless options[:force]
      warn "Output directory '#{output_dir}' already exists"
      exit 1
    end
    FileUtils.rm_rf output_dir
  end
  FileUtils.mkdir_p output_dir
  File.write("#{output_dir}/options.yml", YAML.dump(config_options))
end

wls = MANIFEST.select do |m|
  options[:suites].any?(m[:suite]) && \
    options[:targets].any?(m[:target])
end

wls.each do |wl|
  o = "#{output_dir}/#{wl[:target]}_#{wl[:suite]}_#{wl[:workload]}.yml"
  cmd = [
    "ruby #{$root}/scripts/rv_elf_estimator.rb",
    options[:estimator_opts].gsub('"', '\"'),
    "-o #{o}",
    wl[:path]
  ].join(' ')
  if options[:dryrun]
    puts cmd
  else
    puts cmd
    system cmd
  end
  wl[:elf_estimate_stats] = o
end

# save the schema
cmd = [
  "ruby #{$root}/scripts/rv_elf_estimator.rb",
  options[:estimator_opts].gsub('"', '\"'),
  "--save-schema #{output_dir}/stat_schema.yml",
  wls.first[:path]
].join(' ')
if options[:dryrun]
  puts cmd
else
  system cmd
end

File.write("#{output_dir}/manifest.yml", YAML.dump(wls)) unless options[:dryrun]

# aggregate
cmd = [
  "ruby #{$root}/scripts/collect_stats.rb",
  "--tag #{options[:tag]}",
  "-o #{output_dir}/all.yml"
].join(' ')
if options[:dryrun]
  puts cmd
else
  system cmd
end

# aggregate by suites
wls.group_by { |wl| wl[:suite] }.each_key do |suite|
  FileUtils.mkdir_p("#{output_dir}/by_suite/#{suite}")
  cmd = [
    "ruby #{$root}/scripts/collect_stats.rb",
    "--tag #{options[:tag]}",
    "--suite #{suite}",
    "-o #{output_dir}/by_suite/#{suite}/all.yml" 
  ].join(" ")
  if options[:dryrun]
    puts cmd
  else
    system cmd
  end
  wls.select{ |wl| wl[:suite] == suite }.group_by { |wl| wl[:target] }.each_key do |target|
    cmd = [
      "ruby #{$root}/scripts/collect_stats.rb",
      "--tag #{options[:tag]}",
      "--suite #{suite}",
      "--target #{target}",
      "-o #{output_dir}/by_suite/#{suite}/#{target}.yml" 
    ].join(" ")
    if options[:dryrun]
      puts cmd
    else
      system cmd
    end
  end
end

# aggregate by target
wls.group_by { |wl| wl[:target] }.each_key do |target|
  FileUtils.mkdir_p("#{output_dir}/by_target/#{target}")
  cmd = [
    "ruby #{$root}/scripts/collect_stats.rb",
    "--tag #{options[:tag]}",
    "--target #{target}",
    "-o #{output_dir}/by_target/#{target}/all.yml" 
  ].join(" ")
  if options[:dryrun]
    puts cmd
  else
    system cmd
  end
  wls.select{ |wl| wl[:target] == target }.group_by { |wl| wl[:suite] }.each_key do |suite|
    cmd = [
      "ruby #{$root}/scripts/collect_stats.rb",
      "--tag #{options[:tag]}",
      "--suite #{suite}",
      "--target #{target}",
      "-o #{output_dir}/by_target/#{target}/#{suite}.yml" 
    ].join(" ")
    if options[:dryrun]
      puts cmd
    else
      system cmd
    end
  end
end
