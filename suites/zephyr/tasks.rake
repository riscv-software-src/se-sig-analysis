
file "#{$root}/.home/.local/bin/west" do
  sh 'pip3 install --no-warn-script-location --user -U west'
end

file "#{$root}/build/zephyr/README.rst" => "#{$root}/.home/.local/bin/west" do
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

file "#{$root}/build/zephyr/zephyr/boards/starfive/visionfive2/Kconfig.defconfig": "#{$root}/build/zephyr/README.rst" do
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

namespace :fetch do
  task zephyr: "#{$root}/build/zephyr"

  task zephyr_sdk: "#{$root}/.home/zephyr-sdk-0.16.6"
end

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
