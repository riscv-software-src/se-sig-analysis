# frozen_string_literal: true

file "#{$root}/.home/bin/repo" do |t|
  FileUtils.mkdir_p(File.dirname(t.name))
  Dir.chdir(File.dirname(t.name)) do
    sh 'wget https://raw.githubusercontent.com/GerritCodeReview/git-repo/7fa149b47a980779f02ccaf1d1dbd5af5ce9abc7/repo'
  end
end

file "#{$root}/build/aosp/.repo/manifest.xml" => "#{$root}/.home/bin/repo" do |t|
  FileUtils.mkdir_p(File.dirname(t.name))
  Dir.chdir "#{$root}/build/aosp" do
    sh [
      '/usr/bin/python3 ~/bin/repo init',
      '--repo-rev=v2.45',
      '--no-use-superproject --manifest-depth=1 --depth=1 --no-tags',
      '-u https://android.googlesource.com/platform/manifest'
    ].join(' ')
    FileUtils.cp("#{$root}/suites/aosp/manifest.xml", "#{$root}/build/aosp/.repo/manifests/se_manifest.xml")
  end
end

file "#{$root}/build/aosp/BUILD" => "#{$root}/build/aosp/.repo/manifest.xml" do
  Dir.chdir "#{$root}/build/aosp" do
    sh '/usr/bin/python3 ~/bin/repo sync -c -j8 -m se_manifest.xml'
  end
  Dir.chdir "#{$root}/build/aosp/build/soong" do
    sh "git apply #{$root}/patches/aosp-soong.patch"
  end
end

file "#{$root}/build/aosp/out/target/product/vsoc_riscv64/system.img" => "#{$root}/build/aosp/BUILD" do
  Dir.chdir "#{$root}/build/aosp" do
    # patch new flags in!!
    sh '/bin/bash -c "source build/envsetup.sh && lunch aosp_cf_riscv64_phone-trunk_staging-userdebug && m"'
  end
end

def elf_file?(f)
  File.size(f) > 4 && File.read(f, 4) == "\x7fELF"
end

def find_executables(path, exes)
  Dir.glob("#{path}/*") do |f|
    if File.directory?(f)
      find_executables(f, exes)
    elsif File.symlink?(f)
      next # skip; it will be picked up on the real path
    elsif File.executable?(f)
      exes << File.realpath(f) if elf_file?(f)
    else
      next
    end
  end
end

file "#{$root}/suites/aosp/manifest.yml": 'build:aosp' do |t|
  exes = []
  find_executables("#{$root}/build/aosp/out/target", exes)
  exes.map! do |f|
    {
      target: :android64_llvm,
      path: f,
      suite: :aosp,
      workload: File.basename(f)
    }
  end
  File.write(t.name, YAML.dump(exes))
end

namespace :fetch do
  task aosp: "#{$root}/build/aosp/BUILD"
end

namespace :build do
  desc 'Build Android Open Source Project'
  task aosp: "#{$root}/build/aosp/out/target/product/vsoc_riscv64/system.img"
end

namespace :manifest do
  namespace :gen do
    task :aosp do
      FileUtils.rm_rf "#{$root}/suites/aosp/manifest.yml"
      Rake::Task["#{$root}/suites/aosp/manifest.yml"].invoke
    end
  end
  task aosp: "#{$root}/suites/aosp/manifest.yml" do
    puts File.read("#{$root}/suites/aosp/manifest.yml")
  end
end
