

file "#{$root}/build/embench_iot/README.md" do
  FileUtils.mkdir_p "#{$root}/build/embench_iot"
  sh "git clone https://github.com/embench/embench-iot.git #{$root}/build/embench_iot"
  Dir.chdir "#{$root}/build/embench_iot" do
    sh 'git checkout -b embench-1.0'
  end
  # sh 'pip3 install --no-warn-script-location --user -U pyelftools'
end

$targets.each do |target_name, target|
  next if target[:xlen] != 32

  file "build/embench_iot/build_#{target_name}/src/crc32/crc32" do
    sh [
      "PATH=#{target[:path]}:${PATH}",
      "#{$root}/build/embench_iot/build_all.py",
      "--builddir=build_#{target_name}",
      "--cc=#{target[:cc]}",
      "--cflags=\"-c #{target[:cflags]}\"",
      "--ldflags=\"#{target[:ldflags]} -v -static\"",
      '--user-libs="-lm"',
      "--arch=riscv#{target[:xlen]}",
      '--chip=generic',
      '--board=ri5cyverilator',
      '-v'
    ].join(' ')
  end
end

file "#{$root}/suites/embench_iot/manifest.yml" do |t|
  Rake::Task['build:embench_iot'].invoke

  manifest = []
  exes = []
  find_executables("#{$root}/build/embench_iot", exes)
  exes.each do |exe|
    target = File.basename(File.dirname(File.dirname(File.dirname(exe)))).gsub('build_', '')
    manifest << {
      target: target.to_sym,
      path: exe.gsub("#{$root}/", ''),
      suite: :embench_iot,
      workload: File.basename(exe)
    }
  end
  File.write(t.name, YAML.dump(manifest))
end

namespace :fetch do
  task embench_iot: "#{$root}/build/embench_iot/README.md"
end

namespace :build do
  # task embench_iot: 'build:musl' do
  desc 'Build EMBENCH-IOT (32-bit targets only)'
  task embench_iot: 'fetch:embench_iot' do
    $targets.each do |target_name, target|
      next if target[:xlen] != 32

      Rake::Task["build/embench_iot/build_#{target_name}/src/crc32/crc32"].invoke
    end
  end
end

namespace :manifest do
  # generate a fresh manifest
  namespace :gen do
    task :embench_iot do
      if File.exist?("#{$root}/suites/embench_iot/manifest.yml")
        FileUtils.rm_f "#{$root}/suites/embench_iot/manifest.yml"
      end

      Rake::Task["#{$root}/suites/embench_iot/manifest.yml"].invoke
    end
  end
  # print the manifest
  task :embench_iot do
    Rake::Task["#{$root}/suites/embench_iot/manifest.yml"].invoke
    puts File.read "#{$root}/suites/embench_iot/manifest.yml"
  end
end
