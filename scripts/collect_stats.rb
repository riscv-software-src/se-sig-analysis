#!/usr/bin/env -S sh -c 'singularity run "`dirname $0`"/../.singularity/image.sif bundle exec ruby "$0" "$@"'
# frozen_string_literal: true

require 'English'
require 'optparse'
require 'terminal-table'
require 'jsonpath'
require 'yaml'

require_relative 'lib/stat'

$root = File.realpath(File.dirname(File.dirname(__FILE__))).freeze
$targets = YAML.load(File.read("#{$root}/targets.yml")).freeze

options = {
  dryrun: false,
  suites: nil,
  targets: nil,
  tag: nil,
  stats: nil,
  list_stats: false,
  output: '-'
}
optparse = OptionParser.new do |parser|
  parser.banner = "Usage: #{File.basename($PROGRAM_NAME)} [options]"

  parser.on('-n', '--dry-run', 'Do not actually run') do
    options[:dryrun] = true
  end
  parser.on('-s', '--suite s1,s2,s3', Array, 'Comma-separated list of suites to collect. If not given, analyzes all suites.') do |suites|
    options[:suites] = suites.map(&:to_sym)
  end
  parser.on('-t', '--target t1,t2,t3', Array, 'Comma-separated list of targets to analyze. If not given, analyzes all targets.') do |targets|
    options[:targets] = targets.map(&:to_sym)
  end
  parser.on('-l', '--list-stats', 'List available stats in the tag, then exit') do
    options[:list_stats] = true
  end
  parser.on('--tag TAG_NAME', String, 'Tag this run with TAG_NAME') do |t|
    options[:tag] = t
  end
  parser.on('--stats s1,s2,s3', Array, 'List of stats to collect, as a JsonPath expression') do |s|
    options[:stats] = s.map(&:to_sym)
  end
  parser.on('-o', '--output FILE', String, "Path to write results, or stdout if '-'") do |f|
    options[:output] = f
  end
  parser.on('-h', '--help', 'Print this help') do
    puts parser
    exit
  end
end

begin
  optparse.parse!
  missing = []
  missing << 'tag' if options[:tag].nil?
  raise OptionParser::MissingArgument, missing.join(', ') unless missing.empty?
rescue OptionParser::InvalidOption, OptionParser::MissingArgument
  warn $ERROR_INFO
  warn
  warn optparse
  exit
end

raise "Could not find tag '#{tag}' in runs" unless File.directory?("#{$root}/runs/#{options[:tag]}")

options[:stats] = ['*'] if options[:stats].nil?

def flatten_schema(schema, rslt = {}, prefix=[])
  case schema[:type]
  when 'object'
    schema[:properties].each do |name, child_schema|
      rslt = flatten_schema(child_schema, rslt, prefix + [name.to_sym])
    end
  when 'array'
    rslt[prefix.join('.')] = "[Array]   #{schema[:description]}"
  when 'number'
    rslt[prefix.join('.')] = "[Integer] #{schema[:description]}"
  else
    raise "unexpected type #{schema[:type]}"
  end
  rslt
end

stat_schema = YAML.load(File.read("#{$root}/runs/#{options[:tag]}/stat_schema.yml"))
flat_stat_schema = flatten_schema(stat_schema)
if options[:list_stats]
  puts Terminal::Table.new(rows: flat_stat_schema.to_a)
  exit
end

# find all available suites and targets from the run
manifest = YAML.load(File.read("#{$root}/runs/#{options[:tag]}/manifest.yml"))
suites = manifest.map { |wl| wl[:suite] }.uniq
targets = manifest.map { |wl| wl[:target] }.uniq

suites =
  if options[:suites].nil?
    suites
  else
    options[:suites].each do |s|
      raise "Suite '#{s}' is not in run with tag '#{options[:tag]}" unless suites.any?(s)
    end

    options[:suites]
  end

targets =
  if options[:targets].nil?
    targets
  else
    options[:targets].each do |t|
      raise "Target '#{t}' is not in run with tag '#{options[:tag]}" unless targets.any?(t)
    end

    options[:targets]
  end

wls = manifest.select do |m|
  suites.any?(m[:suite]) && \
    targets.any?(m[:target])
end

def add_stat(collected_stats, wl_stats, path)
  if wl_stats.is_a?(Hash)
    if wl_stats[path[0].to_sym].is_a?(Hash)
      collected_stats[path[0].to_sym] ||= {}
      add_stat(collected_stats[path[0].to_sym], wl_stats[path[0].to_sym], path[1..])
    elsif wl_stats[path[0].to_sym].is_a?(Integer)
      collected_stats[path[0].to_sym] ||= 0
      collected_stats[path[0].to_sym] += wl_stats[path[0].to_sym]
    elsif wl_stats[path[0].to_sym].is_a?(Array)
      collected_stats[path[0].to_sym] ||= []
      add_stat(collected_stats[path[0].to_sym], wl_stats[path[0].to_sym], path[1..])
    end
  elsif wl_stats.is_a?(Array)
    idx = path[0].gsub(/\[\]/,'').to_i
    if wl_stats[idx].is_a?(Integer)
      collected_stats[idx] ||= 0
      collected_stats[idx] += wl_stats[idx]
    elsif wl_stats[idx].is_a?(Hash)
      collected_stats[idx] ||= {}
      add_stat(collected_stats[idx], wl_stats[idx], path[1..])
    elsif wl_stats[idx].is_a?(Array)
      collected_stats[idx] ||= []
      add_stat(collected_stats[idx], wl_stats[idx], path[1..])
    end
  end
end

collected_stats = {}
wls.each do |wl|
  wl_stats = YAML.load(File.read(wl[:elf_estimate_stats]))
  options[:stats].each do |s|
    paths = Jsonata.new(wl_stats).expand_paths(s.to_s)
    paths.each do |path|
      add_stat(collected_stats, wl_stats, path.gsub('[', '.[').split('.'))
    end
  end
end

if options[:output] == '-'
  puts YAML.dump(collected_stats)
else
  File.write(options[:output], YAML.dump(collected_stats))
end

