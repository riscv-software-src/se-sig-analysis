#!/usr/bin/env ruby
# frozen_string_literal: true

require 'yaml'

$root = File.realpath(File.dirname(__FILE__))

RTOS32_CFLAGS = '-march=rv32ima_zba_zbb_zbs_zca_zcb_zcmp_zcmt -mabi=ilp32 -Os'
RTOS64_CFLAGS = '-march=rv64ima_zba_zbb_zbs_zca_zcb_zcmp_zcmt -mbabi=lp64 -Os'

EMBED_RICHOS32_CFLAGS = '-march=rv32ima_zba_zbb_zbs_zca_zcb_zcmp -mabi=ilp32 -Os'
EMBED_RICHOS64_CFLAGS = '-march=rv64ima_zba_zbb_zbs_zca_zcb_zcmp -mabi=lp64 -Os'

APP_RICHOS64_CFLAGS = '-march=rv64gcv_zba_zbb_zbs_zca_zcb -mabi=lp64d -Ofast'

RTOS64_LLVM_FLAGS = "-target riscv64-unknown-elf #{RTOS64_CFLAGS} -emit-llvm"

$targets = YAML.load(File.read("#{$root}/targets.yml")).freeze

load "#{$root}/suites/aosp/tasks.rake"
load "#{$root}/suites/embench_iot/tasks.rake"
load "#{$root}/suites/speccpu2017/tasks.rake"

RV32_LLVM_EMBED_LDFLAGS = '-target riscv32-unknown-elf -menable-experimental-extensions -march=rv32ima_zba_zbb_zbs_zca_zcb_zcmp_zcmt -mabi=ilp32 -flto'

file "#{$root}/.home/.local/bin/west" do
  sh 'pip3 install --no-warn-script-location --user -U west'
end

file "#{$root}/build/zephyr" => "#{$root}/.home/.local/bin/west" do
  sh "PATH=~/.local/bin:${PATH} west init --mr v3.6.0 #{$root}/build/zephyr"
  Dir.chdir("#{$root}/build/zephyr") do
    sh 'PATH=~/.local/bin:${PATH} west update'
    sh 'PATH=~/.local/bin:${PATH} west zephyr-export'
    sh 'pip3 install --user --no-warn-script-location -r zephyr/scripts/requirements.txt'
  end
end

file "#{$root}/.home/zephyr-sdk-0.16.6" do
  Dir.chdir ENV['HOME'] do
    sh 'wget https://github.com/zephyrproject-rtos/sdk-ng/releases/download/v0.16.6/zephyr-sdk-0.16.6_linux-x86_64.tar.xz'
    sh 'tar xf zephyr-sdk-0.16.6_linux-x86_64.tar.xz'
    Dir.chdir 'zephyr-sdk-0.16.6' do
      sh 'yes | ./setup.sh'
    end
  end
end

file "#{$root}/build/openwrt/opennds/README.md" do |t|
  FileUtils.mkdir_p File.dirname(t.name)
  sh "git clone --depth=1 --branch v10.2.0 https://github.com/openNDS/openNDS.git #{$root}/build/openwrt/opennds"
end

# file "#{$root}/build/musl-#{MUSL_VER}/configure" do
#   sh "git clone https://git.musl-libc.org/git/musl --depth 1 --branch v#{MUSL_VER} #{$root}/build/musl-#{MUSL_VER}"
# end

# file "#{$root}/build/musl-#{MUSL_VER}/riscv32_build/config.mak" => "#{$root}/build/musl-#{MUSL_VER}/configure" do
#   FileUtils.mkdir_p "#{$root}/build/musl-#{MUSL_VER}/riscv32_build"
#   Dir.chdir "#{$root}/build/musl-#{MUSL_VER}/riscv32_build" do
#     sh [
#       'CC=/usr/bin/clang-18',
#       'AR=/usr/bin/llvm-ar-18',
#       'RANLIB=/usr/bin/llvm-ranlib-18',
#       "CFLAGS=\"#{RV32_LLVM_EMBED_CFLAGS} -c\"",
#       "LDFLAGS=\"#{RV32_LLVM_EMBED_LDFLAGS}\"",
#       "../configure --disable-shared --prefix=#{$root}/build/musl-#{MUSL_VER}/riscv32_sys$root --target=riscv32-unknown-elf --build=#{`gcc -dumpmachine`.strip}"
#     ].join(' ')
#   end
# end

# file "#{$root}/build/musl-#{MUSL_VER}/riscv32_build/lib/libc.a" => "#{$root}/build/musl-#{MUSL_VER}/riscv32_build/config.mak" do
#   Dir.chdir "build/musl-#{MUSL_VER}/riscv32_build" do
#     sh 'make'
#   end
# end

# file "#{$root}/build/musl-#{MUSL_VER}/riscv32_sys$root/usr/include/bits/alltypes.h" => "#{$root}/build/musl-#{MUSL_VER}/riscv32_build/lib/libc.a" do
#   Dir.chdir "build/musl-#{MUSL_VER}/riscv32_build" do
#     sh 'make install'
#   end
# end

file "#{$root}/build/libmicrohttpd-1.0.1.tar.gz" do
  Dir.chdir "#{$root}/build" do
    sh "wget https://ftp.gnu.org/gnu/libmicrohttpd/libmicrohttpd-1.0.1.tar.gz"
  end
end

file "#{$root}/build/libmicrohttpd-1.0.1/README": "#{$root}/build/libmicrohttpd-1.0.1.tar.gz" do
  Dir.chdir "#{$root}/build" do
    sh "tar zxf libmicrohttpd-1.0.1.tar.gz"
    sh "touch #{$root}/build/libmicrohttpd-1.0.1/README"
  end
end

$targets.each do |target_name, target|
  file "#{$root}/install/#{target_name}/lib/libmicrohttpd.la" => "#{$root}/build/libmicrohttpd-1.0.1/build_#{target_name}/src/microhttpd/libmicrohttpd.la" do
    Dir.chdir "#{$root}/build/libmicrohttpd-1.0.1/build_#{target_name}" do
      sh 'make install'
    end
  end
end

$targets.each do |target_name, target|
  file "#{$root}/build/libmicrohttpd-1.0.1/build_#{target_name}/src/microhttpd/libmicrohttpd.la" =>
    "#{$root}/build/libmicrohttpd-1.0.1/build_#{target_name}/Makefile"  do

    Dir.chdir "#{$root}/build/libmicrohttpd-1.0.1/build_#{target_name}" do
      sh 'make'
    end
  end
end

$targets.each do |target_name, target|
  file "#{$root}/build/libmicrohttpd-1.0.1/build_#{target_name}/Makefile" => "#{$root}/build/libmicrohttpd-1.0.1/README" do |t|
    FileUtils.mkdir_p File.dirname(t.name)
    Dir.chdir "#{$root}/build/libmicrohttpd-1.0.1/build_#{target_name}" do
      sh "CC=#{target[:cc]} CFLAGS=\"#{target[:cflags]}\" LDFLAGS=\"#{target[:ldflags]}\" ../configure --host=#{target[:triple]} --prefix=#{$root}/install/#{target_name}"
    end
  end
end

$targets.each do |target_name, target|
  file "#{$root}/build/openwrt/opennds/opennds" do
    Dir.chdir "#{$root}/build/openwrt/opennds/build_#{target_name}" do
      sh "CC=#{target[:cc]} CFLAGS=\"#{target[:cflags]} -I#{$root}/install/#{target_name}/include\" LDFLAGS=\"#{target[:ldflags]} -static -L#{$root}/install/#{target_name}/lib\" make -C #{$root}/build/openwrt/opennds"
    end
  end
end

$targets.each do |target_name, target|
  file "#{$root}/install/#{target_name}/bin/opennds" do
    sh "CC=#{target[:cc]} CFLAGS=\"#{target[:cflags]} -I#{$root}/install/#{target_name}/include\" LDFLAGS=\"#{target[:ldflags]} -L#{$root}/install/#{target_name}/lib\" make -C #{$root}/build/openwrt/opennds"
  end
end

## Linux Kernel
file "#{$root}/build/linux-kernel/README" do |t|
  FileUtils.mkdir_p(File.dirname(t.name))

  Dir.chdir(File.dirname(t.name)) do
    sh "git clone --depth=1 -b v6.9 https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git ."
  end
end

namespace :tools do
  task west: "#{$root}/.home/.local/bin/west"
end

namespace :fetch do
  task libmicrohttpd: "#{$root}/build/libmicrohttpd-1.0.1/README"

  namespace :openwrt do
    task opennds: ['fetch:libmicrohttpd', "#{$root}/build/openwrt/opennds/README.md"]
  end
  task openwrt: ['openwrt:opennds']

  task zephyr: "#{$root}/build/zephyr" do
    # add Zb* to the compile flags
    Dir.glob("#{$root}/build/zephyr/zephyr/boards/riscv/**/Kconfig.defconfig") do |f|
      File.write(f, File.read(f) + <<~CONFIG
        config RISCV_ISA_EXT_ZBA
          default y

        config RISCV_ISA_EXT_ZBC
          default y

        config RISCV_ISA_EXT_ZBS
          default y
      CONFIG
      )
    end
  end

  task zephyr_sdk: "#{$root}/.home/zephyr-sdk-0.16.6"

  # task musl: "#{$root}/build/musl-#{MUSL_VER}"
end

namespace :build do
  desc 'Build the Android Open Source Project userspace'
  task aosp: "#{$root}/build/aosp/out/target/product/vsoc_riscv64/system.img"

  desc 'Build Zephyr example applications'
  namespace :zephyr do
    desc "Build Zephyr 'http_client' example"
    task http_client: ['fetch:zephyr', 'fetch:zephyr_sdk'] do
      Dir.chdir "#{$root}/build/zephyr/zephyr" do
        sh ['PATH=~/.local/bin:${PATH} west build',
            '--sysbuild -p always -b hifive_unleashed samples/net/sockets/http_client',
            '-- -DCONF_FILE="prj.conf overlay-tls.conf"'].join(' ')
      end
    end
  end

  task libmicrohttpd: ['fetch:libmicrohttpd'] do
    $targets.each do |target_name, target|
      next unless target[:class] == :linux

      Rake::Task["#{$root}/install/#{target_name}/lib/libmicrohttpd.la"].invoke
    end
  end

  desc 'Build OpenWRT for embeded $targets'
  namespace :openwrt do
    task opennds: ['fetch:openwrt:opennds', 'build:libmicrohttpd'] do
      $targets.each do |target_name, target|
        next unless target[:class] == :linux

        break
      end
    end
  end

  # task musl: "#{$root}/build/musl-#{MUSL_VER}/riscv32_sys$root/usr/include/bits/alltypes.h"
 
  task all: ['build:spec2017_llvm', 'build:spec2017_gcc', 'build:zephyr:http_client']
end

namespace :show do
  task :android do
    exes = []
    find_executables("#{$root}/build/aosp/out/target/product/vsoc_riscv64", exes)
    pp exes

    puts "Found #{exes.size} executables"
  end

  task :embench_iot do
    exes = []
    find_executables("#{$root}/build/embench_iot", exes)
    pp exes

    puts "Found #{exes.size} executables"
  end


  desc 'Show all built binaries/libraries'
  task all: ['show:android']
end

namespace :clean do
  task :spec_cpu2017_llvm do
    sh "#{$root}/build/speccpu2017/bin/runcpu --config=#{$root}/clang-18.cfg --action=build intrate fprate"
  end

  task :spec_cpu2017_gcc do
    sh "#{$root}/build/speccpu2017/bin/runcpu --config=#{$root}/gcc-13.cfg --action=build intrate fprate"
  end

  task all: ['clean:spec2017_llvm', 'clean:spec2017_gcc', 'clean:zephyr:http_client']
end

namespace :registry do
  task :login do
    raise "You must put your Docker Hub Access Token into #{$root}/.dockerhub.token" unless File.exist?("#{$root}/.dockerhub.token")

    sh "cat #{$root}/.dockerhub.token | singularity registry login -u dhowerqc --password-stdin oras://docker.io"
  end
end
