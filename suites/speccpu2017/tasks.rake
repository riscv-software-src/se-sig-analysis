file "#{$root}/build/speccpu2017/README" do
  warn "SPEC CPU 2017 must be manually extracted since it is proprietary code"
  warn "  Extract/copy the image to #{$root}/build/speccpu2017, and try again."
  warn "  The directory should look like:"
  warn "    benchspec/"
  warn "    bin/"
  warn "    config/"
  warn "    cshrc*"
  warn "    Docs/"
  warn "    Docs.txt/"
  warn "    install.bat"
  warn "    ..."
end

file "#{$root}/build/speccpu2017/benchspec/CPU/500.perlbench_r/exe/perlbench_r_peak.linux64_app_llvm-m64" do
  sh "#{$root}/build/speccpu2017/bin/runcpu --config=#{$root}/suites/speccpu2017/linux64_app_llvm.cfg --action=build --tuning=peak intrate fprate"
end

file "#{$root}/build/speccpu2017/benchspec/CPU/500.perlbench_r/exe/perlbench_r_peak.linux64_app_gcc-m64" do
  sh "#{$root}/build/speccpu2017/bin/runcpu --config=#{$root}/suites/speccpu2017/linux64_app_gcc.cfg --action=build --tuning=peak intrate fprate"
end

file "#{$root}/suites/speccpu2017/manifest.yml": 'build:speccpu2017' do |t|
  manifest = []
  ['llvm', 'gcc'].each do |c|
    Dir.glob("#{$root}/build/speccpu2017/benchspec/CPU/*/exe/*linux64_app_#{c}*") do |f|
      manifest << {
        target: "linux64_app_#{c}".to_sym,
        path: f.gsub("#{$root}/", ''),
        suite: :speccpu2017,
        workload: File.basename(f).gsub("linux64_app_#{c}-m64", '')
      }
    end
  end
  File.write(t.name, YAML.dump(manifest))
end

namespace :fetch do
  task speccpu2017: "#{$root}/build/speccpu2017/README"
end

namespace :build do
  desc "Build SPEC CPU 2017"
  task speccpu2017: [
    "#{$root}/build/speccpu2017/benchspec/CPU/500.perlbench_r/exe/perlbench_r_peak.linux64_app_llvm-m64",
    "#{$root}/build/speccpu2017/benchspec/CPU/500.perlbench_r/exe/perlbench_r_peak.linux64_app_gcc-m64"
  ]
end

namespace :manifest do
  namespace :gen do
    task speccpu2017: 'build:speccpu2017' do
      if File.exist?("#{$root}/suites/speccpu2017/manifest.yml")
        FileUtils.rm_f("#{$root}/suites/speccpu2017/manifest.yml")
      end

      Rake::Task["#{$root}/suites/speccpu2017/manifest.yml"].invoke
    end
  end
  # print hte manfiest
  task :speccpu2017 do
    Rake::Task["#{$root}/suites/speccpu2017/manifest.yml"].invoke
    puts File.read "#{$root}/suites/speccpu2017/manifest.yml"
  end
end

namespace :clean do
  task :speccpu2017 do
    sh "#{$root}/build/speccpu2017/bin/runcpu --config=#{$root}/suites/speccpu2017/linux64_app_gcc.cfg --action=clean intrate fprate"
    sh "#{$root}/build/speccpu2017/bin/runcpu --config=#{$root}/suites/speccpu2017/linux64_app_llvm.cfg --action=clean intrate fprate"
  end
end
