#!/usr/bin/env -S sh -c 'singularity run "`dirname $0`"/../.singularity/image.sif bundle exec ruby "$0" "$@"'
# frozen_string_literal: true

# Author: Derek R. Hower

ROOT = File.realpath(File.dirname(__FILE__))

require 'optparse'
require 'yaml'

require_relative 'lib/stat'

options = {
  use_bundle: true,
  elf_section: '.text',
  long_literal: false,
  # only_stack_pointer: true,
  pair_offset_multiplier: 256,
  zics_ldstp: false,
  zilsd: false,
  xtheadmempair: false,
  ldstpair_sp: false,
  stat_output: nil,
  save_schema: nil
}
opt = OptionParser.new do |opts|
  opts.banner = "Usage: #{File.basename(__FILE__)} [options] ELF_FILE|LION_FILE"

  opts.on('-s', '--section NAME', "ELF section name to analyze. Default: #{options[:elf_section]}") do |s|
    options[:elf_section] = s
  end

  # opts.on('-p', '--not-just-stack-pointer', 'Do not limit load/store pair to the stack pointer') do
  #   options[:only_stack_pointer] = false
  # end

  opts.on('-o', '--stat-output FILE', "Write stats to output file FILE") do |f|
    options[:stat_output] = f
  end

  opts.on('--save-schema FILE', 'Save the stat schema to FILE, then exit') do |f|
    options[:save_schema] = f
  end

  opts.on('--pair-offset-multiplier M', 'Max offset, as a multiplier on the ld/st size') do |o|
    options[:pair_offset_multiplier] = o.to_i
  end

  opts.on('-l', '--long-literal', 'Include a long literal substitution') do
    options[:long_literal] = true
  end

  opts.on('--zilsd', 'Include Zilsd instructions') do
    options[:zilsd] = true
  end

  opts.on('--xtheadmempair', "Include XTheadMemPair extensions") do
    options[:xtheadmempair] = true
  end

  opts.on('--zics_ldstp', "Stack-relative load/store pair (Zics)") do
    options[:zics_ldstp] = true
  end
end

opt.parse!

if ARGV.length != 1
  warn 'Missing elf file!'
  warn
  warn opt
  exit 1
end

require 'elftools'
require 'terminal-table'

if File.read(ARGV[0], 4)[1, 3] == 'ELF'

  options[:elf_file] = ARGV[0]

  elf = ELFTools::ELFFile.new(File.open(options[:elf_file]))

  section = elf.section_by_name(options[:elf_section])

  raise "Couldn't find section '#{options[:elf_section]}" if section.nil?

  options[:input_type] = :static
else
  options[:lion_file] = ARGV[0]
  options[:input_type] = :dynamic
  # raise "not an ELF or LION file" unless options[:lion_file].read(2) == "LT"

  # options[:lion_file].rewind
end

# CInstruction represents a compressed (16-bit encoding) instruction
# It has an identical interface to Instructin (32-bit encoding)
class CInstruction
  attr_reader :encoding, :pc

  def initialize(encoding, pc)
    raise 'encoding should be an int' unless encoding.is_a?(Integer)

    warn "not a 16-bit encoding: #{encoding.to_s(16)}" unless (encoding & 0x3) != 0x3

    @encoding = encoding
    @pc = pc
  end

  def compressed?
    true
  end

  def compressible?
    true
  end

  def size
    16
  end

  def size_bytes
    2
  end

  def has_dest?
    @encoding != 0 ||
      ((@encoding & 0x3).zero? && (@encoding & 0x8000).zero?) || # bottom half of quad 0
      ((@encoding & 0x3 == 0b01) &&
        !([0b101, 0b110, 0b111].any?(@encoding & 0xe000) >> 13)  # all but last three encodings of quad 1
      ) ||
      ((@encoding & 0x3 == 0b10) &&
        ((@encoding >> 13) <= 0b100) # all but the stores in quad 2
      )
  end

  def is_lui
    @encoding & 0xe003 == 0x6001
  end

  def is_int_load
    [0x4000, 0x6000, 0x4002].any?(@encoding & 0xe003) ||
      ([0x6000, 0x6002].any?(@encoding & 0xe003) && @base != 32) ||
      ([0x8000, 0x8400].any?(@encoding & 0xfc03)) || # c.lbu, c.lhu
      (0x8440 == (@encoding & 0xfc40)) # c.lh
  end

  def is_fp_load
    [0x2000, 0x2002].any?(@encoding & 0xe003) || \
    ([0x6000, 0x6002].any?(@encoding & 0xe003) && @base == 32)
  end

  def is_load
    is_int_load || is_fp_load
  end

  def ld_datatype
    case (@encoding & 0xfc03)
    when 0x8000 # c.lbu
      return :bu
    when 0x8400 # c.lhu
      return :hu
    end

    return :h if (@encoding & 0xfc40) == 0x8440

    case (@encoding & 0xe003)
    when 0x4000 # c.lw
      :w
    when 0x6000 # c.flw (RV32), c.ld (RV64)
      @base == 32 ? :sfp : :d
    when 0x2000 # c.fld (RV32/RV64)
      :sfp
    when 0x4002 # c.lwsp
      :w
    when 0x6002 # c.flwsp (RV32), c.ldsp (RV64)
      @base == 32 ? :sfp : :d
    when 0x2002 # c.fldsp
      :dfp
    else
      raise 'unexpected'
    end
  end

  def is_int_store
    [0xc000, 0xc002].any?(@encoding & 0xe003) || \
      ([0xe000, 0xe002].any?(@encoding & 0xe003) && @base != 32)
  end

  def is_fp_store
    [0xa000, 0x2002].any?(@encoding & 0xe003) || \
      ([0xe000, 0xe002].any?(@encoding & 0xe003) && @base == 32)
  end

  def is_store
    is_int_store || is_fp_store
  end

  def st_datatype
    case (@encoding & 0xe003)
    when 0xc000
      :w
    when 0xc002
      :w
    when 0xa000
      :dfp
    when 0xa002
      :dfp
    when 0xe000
      @base == 32 ? :sfp : :d
    when 0xe002
      @base == 32 ? :sfp : :d
    else
      raise 'unexpected'
    end
  end

  def is_add
    (@encoding & 0xe003 == 0x8002) ||
      (@encoding & 0xe003 == 0x8001)
  end

  def is_addi
    @encoding != 0 &&
      (
        (@encoding & 0xe003 == 0x0001) || # c.addi
        (@encoding & 0xe003 == 0x6001) || # c.addi16sp
        (@encoding & 0xe003 == 0x0000) # c.add4spn
      )
  end

  def is_sh_add
    false
  end

  def is_auipc
    false
  end

  def is_slli
    @encoding & 0xe003 == 0x0002
  end

  def is_jalr
    @encoding & 0xe003 == 0x8002
  end

  def is_jal
    @encoding & 0xe003 == 0x2001
  end

  def is_branch
    @encoding & 0xc003 == 0xc001
  end

  def shamt
    raise 'unexpected'
  end

  def rs1
    # c.addi16sp, c.addi4spn, c.ldsp c.lwsp
    if [0x6001, 0x0000, 0x4002, 0x6002].any?(@encoding & 0xe003)
      2
    elsif @encoding & 0x3 == 0x0
      ((@encoding >> 7) & 0x7) + 8
    elsif (@encoding & 0x3 == 0x1) && (@encoding & 0x8000).positive?
      (@encoding & 0x380) >> 5
    else
      (@encoding & 0xf80) >> 7
    end
  end

  def rs2
    if (@encoding & 0x3 != 2)
      @encoding & 0x1c
    else
      (@encoding & 0x7c) >> 2
    end
  end

  def rd
    if (@encoding & 0x3).zero?
      @encoding & 0x1c
    elsif (((@encoding & 0x3) == 0b01) && (@encoding & 0x8000).zero? ||
           (@encoding & 0x3) == 0b10)
      (@encoding >> 7) & 0x1f
    elsif ((@encoding & 0x3) == 0b01) && (@encoding & 0x8000).positive?
      (@encoding & 0x380) >> 5
    end
  end

  def ld_offset
    case (@encoding & 0xfc03)
    when 0x8000 # c.lbu
      return ((@encoding & 0x20) >> 4) & ((@encoding & 0x40) >> 6)
    when 0x8400 # c.lhu
      return ((@encoding & 0x20) >> 4)
    end
    return ((@encoding & 0x20) >> 4) if (@encoding & 0xfc40) == 0x8440 # c.lh

    if @encoding & 0xe003 == 0x4000
      ((@encoding & 0x1c00) >> 7) |
        ((@encoding & 0x40) >> 5) |
        ((@encoding & 0x20) << 1)
    elsif (@encoding & 0xe003) == 0x4002
      ((@encoding & 0xc) << 4) |
        ((@encoding & 0x1000) >> 7) |
        ((@encoding & 0x70) >> 2)
    elsif (@encoding & 0xe003) == 0x6002
      ((@encoding & 0x1c) << 4) |
        ((@encoding & 0x1000) >> 7) |
        ((@encoding & 0x60) >> 2)
    else
      ((@encoding & 0x1c00) >> 7) |
        ((@encoding & 0x60) << 1)
    end
  end

  def st_offset
    if @encoding & 0xe003 == 0xc002 # c.swsp
      ((@encoding & 0x1e00) >> 7) |
        (@encoding & 0x180) >> 1
    elsif @encoding & 0xe003 == 0xe002 # c.sdsp
      ((@encoding & 0x1c00) >> 6) |
        (@encoding & 0x380) >> 1
    elsif @encoding & 0xe003 == 0x4000
      ((@encoding & 0x1c00) >> 7) |
        ((@encoding & 0x40) >> 5) |
        ((@encoding & 0x20) << 1)
    else
      ((@encoding & 0x1c00) >> 7) |
        ((@encoding & 0x60) << 1)
    end
  end

  def aupic_offset
    raise "unexepcted"
  end

  def is_li
    (@encoding & 0xe003) == 0x4001
  end

  def li_imm
    imm = ((@encoding & 0x7c) >> 2) |
          ((@encoding & 0x1000) >> 7)
    imm = -((~imm + 1) & 0x3f) if (imm & 0x20) != 0
    imm
  end

  def is_mv
    (@encoding & 0xe003) == 0x8002
  end

  def ldst_size
    case (@encoding & 0xfc03)
    when 0x8000 # c.lbu
      return 1
    when 0x8400 # c.lhu
      return 2
    end

    return 2 if (@encoding & 0xfc40) == 0x8440

    if [0x4000, 0xc000, 0x4002, 0xc002, 0x2000].any?(@encoding & 0xe003)
      4
    elsif [0x6000, 0xe000, 0x6002, 0xe002, 0xa000].any?(@encoding & 0xe003)
      8
    else
      raise "unexpected #{@encoding.to_s(16)} #{(@encoding & 0xe003).to_s(16)}"
    end
  end
end

# representation of a 32-bit instruction
# same interface as a CInstruction
class Instruction
  attr_reader :encoding, :pc

  # register numbers of regs accessible by C ext prime specifiers (rd', rs1', rs2')
  COMP_REGS = [8, 9, 10, 11, 12, 13, 14, 15].freeze

  def initialize(encoding, pc)
    raise 'encoding should be an int' unless encoding.is_a?(Integer)

    warn "not a 32-bit encoding: #{encoding.to_s(16)}" unless (encoding & 0x3) == 0x3

    @encoding = encoding
    @pc = pc
  end

  def size
    32
  end

  def size_bytes
    4
  end

  def has_dest?
    is_lui ||
      is_auipc ||
      is_jal ||
      is_jalr ||
      is_load ||
      is_op_imm ||
      is_op ||
      is_op_32 ||
      is_op_imm_32
  end

  def compressed?
    false
  end

  # true if there is a compressed encoding of this instruction
  def compressible?
    if is_load
      size = ldst_size
      return false, :unsupported_inst_type if size < 4

      if rs1 == 2 # stack pointer
        return false, :unsupported_reg if rd.zero?

        offset = ld_offset
        if (offset & 0x3 != 0) || (offset < 0) || (size == 4 && offset >= 128) || (size == 8 && offset >= 256)
          return false, :unsupported_offset
        end

        return true, nil
      else # not stack pointer
        return false, :unsupported_reg unless COMP_REGS.any?(rs1)

        return false, :unsupported_reg unless COMP_REGS.any?(rd)

        offset = ld_offset
        if (offset & 0x3 != 0) || (offset < 0) || (size == 4 && offset >= 64) || (size == 8 && offset >= 128)
          return false, :unsupported_offset
        end
      end
      return true, nil # good load
    elsif is_store
      size = ldst_size
      return false, :unsupported_inst_type if size < 4

      # sd      s0,24(sp)  => c.sdsp  s0,24(sp)
      if rs1 == 2 # stack pointer
        offset = st_offset
        if (offset & 0x3 != 0) || (offset < 0) || (size == 4 && offset >= 128) || (size == 8 && offset >= 256)
          return false, :unsupported_offset
        end
        return true, nil
      else # not stack pointer
        return false, :unsupported_reg unless COMP_REGS.any?(rs1)

        return false, :unsupported_reg unless COMP_REGS.any?(rs2)

        offset = st_offset
        if (offset & 0x3 != 0) || (offset < 0) || (size == 4 && offset >= 64) || (size == 8 && offset >= 128)
          return false, :unsupported_offset
        end
      end
      return true, nil # good store
    elsif is_jal
      offset = jal_offset
      return false, :unsupported_reg unless rd == 0 || rd == 1

      return false, :unsupported_offset if offset < -2048 || offset >= 2048

      return true, nil # good JAL
    elsif is_jalr
      offset = jalr_offset
      return false, :unsupported_reg if rs1.zero?

      return false, :unsupported_reg unless rd == 0 || rd == 1

      return false, :unsupported_offset if offset != 0

      return true, nil # good JALR
    elsif is_branch
      if !is_branch_eqz || !is_branch_nez
        return false, :unsupported_inst_type
      end
      if !COMP_REGS.any?(rs1)
        return false, :unsupported_reg
      end
      if branch_offset < 256 || branch_offset > 256
        return false, :unsupported_offset
      end
      return true, nil # good branch
    elsif is_addi
      imm = i_fmt_imm
      if rd == 0
        return true, nil # c.nop
      end
      if rs1 == 0
        # c.li
        if imm < -32 || imm >= 32
          return false, :unsupported_offset
        end
      elsif rs1 == 2
        if rd == 2
          # c.addi16sp
          if imm >= -512 && imm < 496 && (imm % 16 == 0)
            return true, nil
          end
        elsif COMP_REGS.any?(rd)
          # c.addi4spn
          if imm >= 0 && imm < 1024 && (imm & 0x3 == 0)
            return true, nil
          end
        end
      end

      # addi    a5,a0,0    => c.mv    a5,a0

      # c.addi
      if rd != rs1
        return false, :unsupported_reg
      end
      if imm == 0 || imm < -32 || imm >= 32
        return false, :unsupported_offset
      end

      return true, nil # good addi
    elsif is_lui
      if rd == 0 || rd == 2
        return false, :unsupported_reg
      end
      if (@encoding & 0xfffe0000) == 0
        return true, nil
      elsif (@encoding & 0xfffe0000) == 0xfffe0000
        return true, nil
      else
        return false, :unsupported_offset
      end
    elsif is_addiw
      if rd == 0
        return false, :unsupported_reg
      elsif rd != rs1
        return false, :unsupported_reg
      end
      imm = i_fmt_imm
      if (imm < -32) || (imm >= 32)
        return false, :unsupported_offset
      end
      return true, nil # good addiw
    elsif is_slli
      if rd == 0 || rd != rs1
        return false, :unsupported_reg
      end
      return true, nil # good slli / srli / srai
    elsif is_srli || is_srai
      if !COMP_REGS.any?(rd) || !COMP_REGS.any?(rs1) || rd != rs1
        return false, :unsupported_reg
      end
      return true, nil # good srli / srai
    elsif is_andi
      if !COMP_REGS.any?(rd) || !COMP_REGS.any?(rs1) || rd != rs1
        return false, :unsupported_reg
      end
      imm = i_fmt_imm
      if imm < -32 || imm >= 32
        return false, :unsupported_offset
      end
    elsif is_add
      if rs1 == 0 && rs2 != 0 && rd != 0
        # c.mv
        return true, nil
      elsif rs1 == rd && rd != 0 && rs2 != 0
        # c.add
        return true, nil
      else
        return false, :unsupported_reg
      end
    elsif is_and || is_or || is_xor || is_sub || is_addw || is_subw
      if !COMP_REGS.any?(rd) || !COMP_REGS.any?(rs1) || !COMP_REGS.any?(rs2) || rd != rs1
        return false, :unsupported_reg
      end
      return true, nil
    end
    return false, :unsupported_inst_type # default
  end

  def branch_offset
    tc = ((@encoding & 0x80000000) >> 19) | ((@encoding & 0x80) << 4) | ((@encoding & 0x7e000000) >> 20) | ((@encoding & 0xf00) >> 7)
    if (tc >> 12 == 0)
      return tc
    else
      return -((~tc + 1) & 0xfff)
    end
  end

  # uses OP-IMM major opcode
  def is_op_imm
    (@encoding & 0x7f) == 0x13
  end

  def is_op_imm_32
    (@encoding & 0x7f) == 0x1b
  end

  # uses OP major opcode
  def is_op
    (@encoding & 0x7f) == 0x33
  end

  def is_op_32
    (@encoding & 0x7f) == 0x3b
  end

  def is_lui
    (@encoding & 0x7f) == 0x37
  end

  def is_int_load
    (@encoding & 0x7f) == 0x3
  end

  def is_fp_load
    (((@encoding & 0x7f) == 0x7) && [1,2,3].any?((@encoding >> 12) & 0x7))
  end

  def is_load
    is_int_load || is_fp_load
  end

  def ld_datatype
    raise "unexpected" unless is_load

    if ((@encoding & 0x7f) == 0x3)
      case (@encoding >> 12) & 0x3
      when 0 then :b
      when 1 then :h
      when 2 then :w
      when 3 then :d
      when 4 then :bu
      when 5 then :hu
      when 6 then :wu
      else raise 'unexpected'
      end
    elsif ((@encoding & 0x7f) == 0x7)
      case (@encoding >> 12) & 0x3
      when 1 then :hfp
      when 2 then :sfp
      when 3 then :dfp
      else raise 'unexpected'
      end
    else
      raise 'unexpected'
    end
  end

  def is_store
    (@encoding & 0x7f) == 0x23
  end

  def st_datatype
    raise "unexpected" unless is_store

    case (@encoding >> 12) & 0x3
    when 0 then :b
    when 1 then :h
    when 2 then :w
    when 3 then :d
    else raise 'unexpected'
    end
  end

  def is_add
    ((@encoding & 0x7f) == 0x33) &&
    (((@encoding >> 12) & 0x7) == 0) &&
    ((@encoding >> 25) == 0)
  end

  def is_addi
    ((@encoding & 0x7f) == 0x13) &&
    (((@encoding >> 12) & 0x7) == 0)
  end

  # any of sh1add, sh1add.uw, sh2add, sh2add.uw, sh3add, sh3add.uw
  def is_sh_add
    ((@encoding & 0x7f) == 0x33) && (((@encoding >> 12) & 0x7) == 2) && ((@encoding >> 25) == 0x10) \
    || ((@encoding & 0x7f) == 0x3B) && (((@encoding >> 12) & 0x7) == 2) && ((@encoding >> 25) == 0x10) \
    || ((@encoding & 0x7f) == 0x33) && (((@encoding >> 12) & 0x7) == 4) && ((@encoding >> 25) == 0x10) \
    || ((@encoding & 0x7f) == 0x3B) && (((@encoding >> 12) & 0x7) == 4) && ((@encoding >> 25) == 0x10) \
    || ((@encoding & 0x7f) == 0x33) && (((@encoding >> 12) & 0x7) == 6) && ((@encoding >> 25) == 0x10) \
    || ((@encoding & 0x7f) == 0x3B) && (((@encoding >> 12) & 0x7) == 6) && ((@encoding >> 25) == 0x10)
  end

  def is_auipc
    (@encoding & 0x7f) == 0x17
  end

  def auipc_offset
    if (@encoding & 0x80000000) == 0
      (@encoding & 0xfffff000)
    else
      -((~(@encoding & 0xfffff000) + 1) & 0xffffffff)
    end
  end

  def is_slli
    ((@encoding & 0x7f) == 0x13) && (((@encoding >> 12) & 0x7) == 1) && ((@encoding >> 25) == 0)
  end

  def is_jalr
    (@encoding & 0x7f) == 0x67 && (((@encoding >> 12) & 0x7) == 0)
  end

  def jalr_offset
    if (@encoding & 0x80000000) == 0
      @encoding >> 20
    else
      -((~(@encoding >> 20) + 1) & 0xfff)
    end
  end

  def is_jal
    (@encoding & 0x7f) == 0x6f
  end

  def jal_offset
    tc = ((@encoding & 0x80000000) >> 11) | (@encoding & 0xff000) | ((@encoding & 0x100000) >> 9) | ((@encoding & 0x7fe00000) >> 20)
    if (tc >> 20 == 0)
      return tc
    else
      return -((~tc + 1) & 0xfffff)
    end
  end

  def is_branch
    (@encoding & 0x7f) == 0x63
  end

  def is_branch_eqz
    is_branch && ((@encoding & 0x7000) == 0) && rs2 == 0
  end

  def is_branch_nez
    is_branch && ((@encoding & 0x7000) == 0x1000) && rs2 == 0
  end


  def shamt
    (@encoding >> 20) & 0x1f
  end

  def rs1
    (@encoding >> 15) & 0x1f
  end

  def rs2
    (@encoding >> 20) & 0x1f
  end

  def rd
    (@encoding >> 7) & 0x1f
  end

  def ld_offset
    if ((@encoding >> 20) & 0x8000) != 0
      return -((~(@encoding >> 20) + 1) & 0xfff)
    else
      return (@encoding >> 20)
    end
  end

  def st_offset
    off = ((@encoding >> 25) << 5) | ((@encoding >> 7) & 0x1f)
    if (off & 0x800) != 0
      return -((~off + 1) & 0xfff)
    else
      return off
    end
  end

  def aupic_offset
    (@encoding & ~0xfff)
  end

  def i_fmt_imm
    imm = @encoding >> 20
    if (imm & 0x800) != 0
      imm = -((~imm + 1) & 0xfff)
    end
    imm
  end

  def is_li
    if is_addi && rs1 == 0
      return true
    end
  end
  
  def li_imm
    if is_addi && rs1 == 0
      return i_fmt_imm
    end
    raise "not li"
  end

  def is_mv
    is_addi && (i_fmt_imm == 0)
  end
  

  def ldst_size
    if ((@encoding & 0x7f) == 0x3) || ((@encoding & 0x7f) == 0x23)
      case ((@encoding >> 12) & 0x7)
      when 0 then return 1
      when 1 then return 2
      when 2 then return 4
      when 3 then return 8
      when 4 then return 1
      when 5 then return 2
      when 6 then return 4
      end
    elsif ((@encoding & 0x7f) == 0x7) || ((@encoding & 0x7f) == 0x27)
      case ((@encoding >> 12) & 0x7)
      when 1 then return 2
      when 2 then return 4
      when 3 then return 8
      end
    end
    puts pc.to_s(16)
    raise "error: #{(@encoding & 0x7f)} #{(@encoding >> 12) & 0x7} #{@encoding.to_s(16)}"
  end
end

def xtheadmempair_ld?(inst_history, options)
  return false unless options[:xtheadmempair]

  # two sequential load instructions
  return false unless inst_history[0].is_load && inst_history[1].is_load

  # same base on loads
  return false unless inst_history[0].rs1 == inst_history[1].rs1

  # not overwritten
  return false unless inst_history[0].rd != inst_history[1].rd

  # no register overlap
  return false unless (inst_history[0].rd != inst_history[0].rs1) && (inst_history[1].rd != inst_history[0].rs1)

  # same datatype, one of [double, word, unsigned word]
  return false unless (inst_history[0].ld_datatype == inst_history[1].ld_datatype) && ([:d, :w, :wu].any?(inst_history[0].ld_datatype))

  # sequential addresses ( in either order )
  return false unless ((inst_history[0].ld_offset + inst_history[0].ldst_size == inst_history[1].ld_offset) \
  || (inst_history[1].ld_offset + inst_history[1].ldst_size == inst_history[0].ld_offset))

  # fits in offset
  case inst_history[0].ld_datatype
  when :d
    return false unless inst_history[0].ld_offset % 16 == 0
    return false unless inst_history[0].ld_offset >= 0 && inst_history[0].ld_offset <= 48 
  when :w, :wu
    return false unless inst_history[0].ld_offset % 8 == 0
    return false unless inst_history[0].ld_offset >= 0 && inst_history[0].ld_offset <= 24
  else
    raise 'bad datatype'
  end

  # success
  return 2
end


def xtheadmempair_st?(inst_history, options)
  return false unless options[:xtheadmempair]

  # two sequential store instructions
  return false unless inst_history[0].is_store && inst_history[1].is_store

  # same base on stores
  return false unless inst_history[0].rs1 == inst_history[1].rs1

  # same datatype, one of [double, word]
  return false unless (inst_history[0].st_datatype == inst_history[1].st_datatype) && ([:d, :w].any?(inst_history[0].st_datatype))

  # sequential addresses ( in either order )
  return false unless ((inst_history[0].st_offset + inst_history[0].ldst_size == inst_history[1].st_offset) \
  || (inst_history[1].st_offset + inst_history[1].ldst_size == inst_history[0].st_offset))

  # fits in offset
  case inst_history[0].st_datatype
  when :d
    return false unless inst_history[0].ld_offset % 16 == 0
    return false unless inst_history[0].ld_offset >= 0 && inst_history[0].ld_offset <= 48 
  when :w
    return false unless inst_history[0].ld_offset % 8 == 0
    return false unless inst_history[0].ld_offset >= 0 && inst_history[0].ld_offset <= 24
  else
    raise 'bad datatype'
  end

  # success
  return 2
end

def zilsd_ld?(inst_history, options)
  return false unless options[:zilsd]

  # two sequential load instructions
  return false unless inst_history[0].is_load && inst_history[1].is_load

  # same base on loads
  return false unless inst_history[0].rs1 == inst_history[1].rs1

  # not overwritten
  return false unless inst_history[0].rd != inst_history[1].rd

  # same datatype, == word
  return false unless (inst_history[0].ld_datatype == :w) && (inst_history[1].ld_datatype == :w)

  # sequential addresses ( in either order )
  return false unless ((inst_history[0].ld_offset + inst_history[0].ldst_size == inst_history[1].ld_offset) \
  || (inst_history[1].ld_offset + inst_history[1].ldst_size == inst_history[0].ld_offset))

  # fits in offset
  return false unless ((inst_history[0].ld_offset <= 2047) && (inst_history[0].ld_offset > -2048))

  # this sequence matches. now just determine if the replacement can be compressed
  if ((inst_history[0].rs1 == 2) && # stack pointer relative
      Instruction::COMP_REGS.any?(inst_history[0].rd) && Instruction::COMP_REGS.any?(inst_history[0].rd + 1) && # fits in rd'
      (inst_history[0].rd != 0) && # not x0 dest
      (inst_history[0].ld_offset >= 0) && (inst_history[0].ld_offset < 508) && (inst_history[0].ld_offset % 8 == 0)) # fits in offset
    # c.ldsp
    return false
  elsif (Instruction::COMP_REGS.any?(inst_history[0].rd) && Instruction::COMP_REGS.any?(inst_history[0].rd + 1) && # fits in rd'
         Instruction::COMP_REGS.any?(inst_history[0].rs1) && # fits in rs1'
         (inst_history[0].ld_offset >= 0) && (inst_history[0].ld_offset < 256)) # fits in offset
    # c.ld
    return false
  else
    # ld
    return 2
  end
end

def zilsd_cldsp?(inst_history, options)
  return false unless options[:zilsd]

  # two sequential load instructions
  return false unless inst_history[0].is_load && inst_history[1].is_load

  # same base on loads
  return false unless inst_history[0].rs1 == inst_history[1].rs1

  # not overwritten
  return false unless inst_history[0].rd != inst_history[1].rd

  # same datatype, == word
  return false unless (inst_history[0].ld_datatype == :w) && (inst_history[1].ld_datatype == :w)

  # sequential addresses ( in either order )
  return false unless ((inst_history[0].ld_offset + inst_history[0].ldst_size == inst_history[1].ld_offset) \
  || (inst_history[1].ld_offset + inst_history[1].ldst_size == inst_history[0].ld_offset))

  # fits in offset
  return false unless ((inst_history[0].ld_offset <= 2047) && (inst_history[0].ld_offset > -2048))

  # this sequence matches. now just determine if the replacement can be compressed
  if ((inst_history[0].rs1 == 2) && # stack pointer relative
      Instruction::COMP_REGS.any?(inst_history[0].rd) && Instruction::COMP_REGS.any?(inst_history[0].rd + 1) && # fits in rd'
      (inst_history[0].rd != 0) && # not x0 dest
      (inst_history[0].ld_offset >= 0) && (inst_history[0].ld_offset < 508) && (inst_history[0].ld_offset % 8 == 0)) # fits in offset
    # c.ldsp
    return 2
  elsif (Instruction::COMP_REGS.any?(inst_history[0].rd) && Instruction::COMP_REGS.any?(inst_history[0].rd + 1) && # fits in rd'
         Instruction::COMP_REGS.any?(inst_history[0].rs1) && # fits in rs1'
         (inst_history[0].ld_offset >= 0) && (inst_history[0].ld_offset < 256)) # fits in offset
    # c.ld
    return false
  else
    # ld
    return false
  end
end

def zilsd_cld?(inst_history, options)
  return false unless options[:zilsd]

  # two sequential load instructions
  return false unless inst_history[0].is_load && inst_history[1].is_load

  # same base on loads
  return false unless inst_history[0].rs1 == inst_history[1].rs1

  # not overwritten
  return false unless inst_history[0].rd != inst_history[1].rd

  # same datatype, == word
  return false unless (inst_history[0].ld_datatype == :w) && (inst_history[1].ld_datatype == :w)

  # sequential addresses ( in either order )
  return false unless ((inst_history[0].ld_offset + inst_history[0].ldst_size == inst_history[1].ld_offset) \
  || (inst_history[1].ld_offset + inst_history[1].ldst_size == inst_history[0].ld_offset))

  # fits in offset
  return false unless ((inst_history[0].ld_offset <= 2047) && (inst_history[0].ld_offset > -2048))

  # this sequence matches. now just determine if the replacement can be compressed
  if ((inst_history[0].rs1 == 2) && # stack pointer relative
      Instruction::COMP_REGS.any?(inst_history[0].rd) && Instruction::COMP_REGS.any?(inst_history[0].rd + 1) && # fits in rd'
      (inst_history[0].rd != 0) && # not x0 dest
      (inst_history[0].ld_offset >= 0) && (inst_history[0].ld_offset < 508) && (inst_history[0].ld_offset % 8 == 0)) # fits in offset
    # c.ldsp
    return false
  elsif (Instruction::COMP_REGS.any?(inst_history[0].rd) && Instruction::COMP_REGS.any?(inst_history[0].rd + 1) && # fits in rd'
         Instruction::COMP_REGS.any?(inst_history[0].rs1) && # fits in rs1'
         (inst_history[0].ld_offset >= 0) && (inst_history[0].ld_offset < 256)) # fits in offset
    # c.ld
    return 2
  else
    # ld
    return false
  end
end

def zics_ld_pair?(inst_history, options)
  return false unless options[:zics_ldstp] == true

  # threre are at least two instructions to consider
  return false unless (inst_history.size > 1)

  # two sequential load instructions
  return false unless inst_history[0].is_load && inst_history[1].is_load

  # same base on loads
  return false unless inst_history[0].rs1 == inst_history[1].rs1

  # base is stack pointer (if restricted thus)
  return false unless inst_history[0].rs1 == 2

  # not overwritten
  return false unless inst_history[0].rd != inst_history[1].rd

  # same datatype
  return false unless inst_history[0].ld_datatype == inst_history[1].ld_datatype

  # sequential addresses ( in either order )
  return false unless ((inst_history[0].ld_offset + inst_history[0].ldst_size == inst_history[1].ld_offset) \
                || (inst_history[1].ld_offset + inst_history[1].ldst_size == inst_history[0].ld_offset))

  # fits in offset
  return false unless ((inst_history[0].ld_offset < inst_history[0].ldst_size*32))

  return 2
end

def zics_st_pair?(inst_history, options)
  return false unless options[:zics_ldstp] == true

  # threre are at least two instructions to consider
  return false unless (inst_history.size > 1)

  # two sequential store instructions
  return false unless inst_history[0].is_store && inst_history[1].is_store

  # same base on stores
  return false unless inst_history[0].rs1 == inst_history[1].rs1

  # base is stack pointer
  return false unless inst_history[0].rs1 == 2

  # same datatype
  return false unless inst_history[0].st_datatype == inst_history[1].st_datatype

  # sequential addresses ( in either order )
  return false unless ((inst_history[0].st_offset + inst_history[0].ldst_size == inst_history[1].st_offset) \
                || (inst_history[1].st_offset + inst_history[1].ldst_size == inst_history[0].st_offset))

  # fits in offset
  return false unless ((inst_history[0].st_offset < inst_history[0].ldst_size*32))

  return 2
end

def ld_reg_reg?(inst_history, reg_history)
  # look for:
  #  0: add ra, ?, ?
  #  1: ld  rd, 0(ra)
  if inst_history[0].is_load
    if reg_history[inst_history[0].rs1].size.positive?
      producer = reg_history[inst_history[0].rs1][0]
      if producer.is_add
        if inst_history[0].ld_offset == 0
          return 2
        end
      end
    end
  end
  return false
end

def st_reg_reg?(inst_history, reg_history)
  # look for:
  #  0: add ra, ?, ?
  #  1: st  rd, 0(ra)
  if inst_history[0].is_store
    if reg_history[inst_history[0].rs1].size.positive?
      producer = reg_history[inst_history[0].rs1][0]
      if producer.is_add
        if inst_history[0].st_offset == 0
          return 2
        end
      end
    end
  end
  return false
end

def ld_pc_rel?(inst_history, reg_history)
  # look for:
  #  0: auipc ra, ?
  #  1: ld rd, ?(ra)
  if inst_history[0].is_load
    load = inst_history[0]
    if reg_history[load.rs1].size.positive?
      producer = reg_history[load.rs1][0]
      if producer.is_auipc
        if load.ld_offset < 2**(12 + Math.log2(load.ldst_size).to_i)
          return 2
        end
      end
    end
  end
  # look for:
  #  0: auipc ra
  #  1: add/addi ra 
  #  2: add/addi ra
  #  3: ld rd, ?(ra)
  # if inst_history.size > 3 && is_load(inst_history[3])
  #   if (is_add(inst_history[2]) || is_addi(inst_history[2])) && (is_add(inst_history[1]) || is_addi(inst_history[1])) && is_auipc(inst_history[0])
  #     return 3
  #   end
  # end
  return false
end

def ld_indexed?(inst_history, register_history)
  # look for:
  #  0: shXadd
  #  1: ld
  if inst_history[0].is_load
    if register_history[inst_history[0].rs1].size.positive?
      if register_history[inst_history[0].rs1][0].is_sh_add
        return 2
      end
    end
  end
  # look for:
  #  0: slli r1, X 
  #  1: add/addi r1, r1, r2
  #  2: ld 0(r1)
  if inst_history[0].is_load
    load = inst_history[0]
    if register_history[load.rs1].size.positive?
      if register_history[load.rs1][0].is_add
        add = register_history[load.rs1][0]
        
        # check rs1
        idx = (add.rd == add.rs1) ? 1 : 0
        if register_history[add.rs1].size > idx
          if register_history[add.rs1][idx].is_slli
            slli = register_history[add.rs1][idx]
            if slli.rd == add.rs1 || slli.rd == add.rs2
              return 3
            end
          end
        end

        # check rs2
        idx = (add.rd == add.rs2) ? 1 : 0
        if register_history[add.rs2].size > idx
          if register_history[add.rs2][idx].is_slli
            slli = register_history[add.rs2][idx]
            if slli.rd == add.rs2 || slli.rd == add.rs2
              return 3
            end
          end
        end
      end
    end
  end
  return false
end

def st_indexed?(inst_history, register_history)
  # look for:
  #  0: shXadd
  #  1: st
  if inst_history[0].is_store
    if register_history[inst_history[0].rs1].size.positive?
      if register_history[inst_history[0].rs1][0].is_sh_add
        return 2
      end
    end
  end
  # look for:
  #  0: slli
  #  1: add/addi
  #  2: st
  if inst_history[0].is_store
    store = inst_history[0]
    if register_history[store.rs1].size.positive?
      if register_history[store.rs1][0].is_add
        add = register_history[store.rs1][0]

        # check rs1 of add
        idx = (add.rd == store.rs1) ? 1 : 0
        if register_history[add.rs1].size > idx
          if register_history[add.rs1][idx].is_slli
            slli = register_history[add.rs1][idx]
            if slli.rd == add.rs1 || slli.rd == add.rs2
              return 3
            end
          end
        end

        # check rs2
        idx = (add.rd == store.rs1) ? 1 : 0
        if register_history[add.rs2].size > idx
          if register_history[add.rs2][idx].is_slli
            slli = register_history[add.rs2][idx]
            if slli.rd == add.rs1 || slli.rd == add.rs2
              return 3
            end
          end
        end
      end
    end
  end
  return false
end

# look for an sp increment after a load; this can be elided with post-update
def ld_sp_inc?(inst_history)
  if inst_history[0].is_addi && inst_history[0].rs1 == 2
    if inst_history.minus(1).is_load && inst_history.minus(1).rs1 == 2
      return 2
    end
  end
  return false
end

# look for an sp increment before a store; this can be elided with pre-update
def st_sp_inc?(inst_history)
  return false unless inst_history.size > 1

  if inst_history[0].is_addi && inst_history[0].rs1 == 2
    if inst_history[1].is_store && inst_history[1].rs1 == 2
      return 2
    end
  end
  return false
end

def long_j?(inst_history, register_history)
  # look for:
  #  0: auipc rd
  #  1: jalr ?(rd)
  if inst_history[0].is_jalr
    if register_history[inst_history[0].rs1].size.positive?
      producer = register_history[inst_history[0].rs1][0]
      if producer.is_auipc
        return 2
      end
    end
  end
  return false
end

def long_literal?(inst_history, register_history, options)
  return false unless options[:long_literal]

  if inst_history[0].is_addi
    if register_history[inst_history[0].rs1].size.positive?
      producer = register_history[inst_history[0].rs1][0]
      if producer.is_lui
        return 2
      end
    end
  end
  return false
end

def branch_imm_cond?(inst_history, register_history)
  if inst_history[0].is_branch
    if register_history[inst_history[0].rs1].size.positive?
      producer1 = register_history[inst_history[0].rs1][0]
      if (producer1.is_li && producer1.li_imm < 128 && producer1.li_imm >= -128)
        return inst_history[0].rs1
      end
    end
    if register_history[inst_history[0].rs2].size.positive?
      producer2 = register_history[inst_history[0].rs2][0]
      if (producer2.is_li && producer2.li_imm < 128 && producer2.li_imm >= -128)
        return inst_history[0].rs2
      end
    end
  end
  return false
end

def double_mv?(inst_history)
  return false if inst_history.size < 2

  if inst_history[0].is_mv
    if inst_history[1].is_mv
      if inst_history[2].is_mv
        if inst_history[3].is_mv
          return 4
        end
      end
    end
  end
  if inst_history[0].is_mv
    if inst_history[1].is_mv
      if inst_history[2].is_mv
        return 3
      end
    end
  end

  # if inst_history[0].is_mv
  #   if inst_history[1].is_mv
  #     return 2
  #   end
  # end
  return false
end

# nloads = 0
# nload_pairs = 0
# nload_reg_reg = 0
# nload_pc_rel = 0
# nload_indexed = 0
# nstores = 0
# nstore_pairs = 0
# nstore_reg_reg = 0
# nstore_indexed = 0
# nsp_add = 0
# nlong_literal = 0
# nj_long = 0
# nbr_cond_imm = 0
# ndouble_mv = 0

pair_offsets = []
encodings =
  if options.key?(:elf_file)
    hws = section.data.unpack('S*')
    es = []
    i = 0
    while i < hws.size
      if (hws[i] & 0x3) == 0x3
        es << (hws[i] | (hws[i+1] << 16))
        i += 2
      else
        es << hws[i]
        i += 1
      end
    end
    es
  else
    raise 'Not a lion or elf file' unless options.key?(:lion_file)

    e = []
    warn 'reading file...'
    insts = `zgrep "o " #{options[:lion_file]}`
    warn 'done'
    insts.each_line do |i|
      enc = i[2, 8]
      e << enc.to_i(16)
    end
    e
  end
ninsts = encodings.size
i = 0

stats = {
  # estimated static instruction count
  est_inst_cnt: Stat.new(0, 'Estimated static instruction count'),

  actual_inst_cnt: Stat.new(encodings.size, 'Actual statis instruction count'),

  # estimated static section size (bytes)
  est_size: Stat.new(0, 'Estimated code size (bytes)'),

  actual_size: Stat.new(section.data.size, 'Actual code size (bytes)'),

  # count of untouched instructions, by type
  unchanged: {
    st: Stat.new(0, 'Number of store instructions that were not affected by the analysis'),
    ld: Stat.new(0, 'Number of load instructinos that were not affected by the analysis')
  },
}

if options[:zilsd]
  stats[:zilsd] = {
    ld: Stat.new(0, 'Number of `ld` instructions found for Zilsd'),
    cld: Stat.new(0, 'Number of `c.ld` instructions found for Zilsd'),
    cldsp: Stat.new(0, 'Number of `c.ldsp` instructions found for Zilsd'),
    sd: Stat.new(0, 'Number of `sd` instructions found for Zilsd'),
    csd: Stat.new(0, 'Number of `c.sd` instructions found for Zilsd'),
    csdsp: Stat.new(0, 'Number of `c.sdsp` instructions found for Zilsd')
  }
end

if options[:xtheadmempair]
  stats[:xtheadmempair] = {
    lwd: Stat.new(0, 'Number of `th.lwd` instructions found for XTheadMemPair'),
    lwud: Stat.new(0, 'Number of `th.lwud` instructions found for XTheadMemPair'),
    ldd: Stat.new(0, 'Number of `th.ldd` instructions found for XTheadMemPair'),
    sdd: Stat.new(0, 'Number of `th.sdd` instructions found for XTheadMemPair'),
    swd: Stat.new(0, 'Number of `th.swd` instructions found for XTheadMemPair')
  }
end

if options[:zics]
  stats[:zics] = {
    ldp: {
      d: {
        cnt: 0,
        offset_histogram: Array.new(256, 0),
        base_histogram: Array.new(32, 0)
      },
      w: {
        cnt: 0,
        offset_histogram: Array.new(128, 0),
        base_histogram: Array.new(32, 0)
      },
      wu: {
        cnt: 0,
        offset_histogram: Array.new(128, 0),
        base_histogram: Array.new(32, 0)
      },
      h: {
        cnt: 0,
        offset_histogram: Array.new(64, 0),
        base_histogram: Array.new(32, 0)
      },
      hu: {
        cnt: 0,
        offset_histogram: Array.new(64, 0),
        base_histogram: Array.new(32, 0)
      },
      b: {
        cnt: 0,
        offset_histogram: Array.new(32, 0),
        base_histogram: Array.new(32, 0)
      },
      bu: {
        cnt: 0,
        offset_histogram: Array.new(32, 0),
        base_histogram: Array.new(32, 0)
      }
    }
  }

  # # histogram of source (rs1) register numbers for ld/st pairs
  # pair_addr_reg: Stat.new(Array.new(32, 0), 'Histogram of source (rs1) register numbers for ld/st pairs'),


  # # reasons why a ld/st pair can't use a C encoding
  # pair_reasons: {
  #   unsigned: 0, # data type is unsigned
  #   offset: 0,   # offset is too large
  #   reg: 0,      # src/dst register doesn't fit in C encoding
  #   size: 0,     # data type size unsupported
  #   other: 0     # should be zero (sanity check)
  # },
  # ld_pair_datatypes: {
  #   b: 0,   # signed byte
  #   bu: 0,  # unsigned byte
  #   h: 0,   # signed halfword
  #   hu: 0,  # unsigned halfword
  #   w: 0,   # signed word
  #   wu: 0,  # unsigned word
  #   d: 0,   # doubleword
  #   sfp: 0, # single-precision FP
  #   dfp: 0  # double-precision FP
  # },
  # ld_pair_base: Array.new(32, 0),
  # st_pair_datatypes: {
  #   b: 0,    # byte
  #   h: 0,    # halfword
  #   w: 0,    # word
  #   d: 0,    # doubleword
  #   sfp: 0,  # single-precision FP
  #   dfp: 0   # double-precision FP
  # },
  # st_pair_base: Array.new(32, 0)
end

# extract desc from Stats
def desc_only(stats)
  ret = {}
  stats.each do |k, v|
    if v.is_a?(Hash)
      ret[k] = desc_only(v)
    elsif v.is_a?(Stat)
      ret[k] = v.desc
    else
      raise "unexpected stat type"
    end
  end
  ret
end

if options[:save_schema]
  schema = StatUtil.gen_schema(stats, options[:save_schema])
  File.write(options[:save_schema], YAML.dump(schema))
  exit
end

# history of instructions writing into a register
reg_history = Array.new(32) { [] }

# wraps an array so that it can be viewed as a subarray
# index 0 of the ArrayView corresponds with index 'idx' of the wrapped array
class ArrayView
  attr_accessor :idx

  def initialize(ary, idx)
    @ary = ary
    @idx = idx
  end

  def minus(idx)
    @ary[@idx - idx]
  end

  def [](idx)
    if idx.negative?
      @ary[@ary.size - idx]
    else
      @ary[@idx + idx]
    end
  end

  def size
    @ary.size - @idx
  end
end

# puts section.header.sh_addr.to_i.to_s(16)
# puts encodings.size
pc = section.header.sh_addr
encodings.map! do |e|
  i = (e & 0x3) == 0x3 ? Instruction.new(e, pc) : CInstruction.new(e, pc)
  # puts "#{pc.to_i.to_s(16)} #{e.to_s(16)}"
  pc += (e & 0x3) == 0x3 ? 4 : 2
  i
end
inst_history = ArrayView.new(encodings, 0)
lsp_savings = 0
while inst_history.idx < encodings.size

  orig_idx = inst_history.idx
  this_inst = encodings[orig_idx]

  if (n = zilsd_ld?(inst_history, options))
    stats[:zilsd][:ld] += 1

    # since this is consuming the current AND next instruction, increment the index by 2
    # so we don't pull in the same load twice
    inst_history.idx += 2
    stats[:est_inst_cnt] += 1
    stats[:est_size] += 4
  elsif (n = zilsd_cld?(inst_history, options))
    stats[:zilsd][:cld] += 1

    # since this is consuming the current AND next instruction, increment the index by 2
    # so we don't pull in the same load twice
    inst_history.idx += 2
    stats[:est_inst_cnt] += 1
    stats[:est_size] += 2
  elsif (n = zilsd_cldsp?(inst_history, options))
    stats[:zilsd][:cldsp] += 1

    # since this is consuming the current AND next instruction, increment the index by 2
    # so we don't pull in the same load twice
    inst_history.idx += 2
    stats[:est_inst_cnt] += 1
    stats[:est_size] += 2
  elsif (n = xtheadmempair_ld?(inst_history, options))
    case (inst_history[0].ld_datatype)
    when :w
      stats[:xtheadmempair][:lwd] += 1
    when :wu
      stats[:xtheadmempair][:lwud] += 1
    when :d
      stats[:xtheadmempair][:ldd] += 1
    else
      raise 'bad datatype'
    end

    inst_history.idx += 2
    stats[:est_inst_cnt] += 1
    stats[:est_size] += 4
  elsif (n = xtheadmempair_st?(inst_history, options))
    case (inst_history[0].st_datatype)
    when :w
      stats[:xtheadmempair][:swd] += 1
    when :d
      stats[:xtheadmempair][:sdd] += 1
    else
      raise 'bad datatype'
    end

    inst_history.idx += 2
    stats[:est_inst_cnt] += 1
    stats[:est_size] += 4

  elsif (n = zics_ld_pair?(inst_history, options))
    stats[:zics][:ldp][inst_history[0].ld_datatype][:cnt] += 1
    stats[:zics][:ldp][inst_history[0].ld_datatype][:offset_histogram][inst_history[0].ld_offset] += 1
    stats[:zics][:ldp][inst_history[0].ld_datatype][:base_histogram][inst_history[0].rs1] += 1
    

    # if !(inst_history[0].size == 16 && inst_history[1].size == 16)
    #   if [4, 5, 6].any?(((inst_history[0].encoding >> 12) & 0x7))
    #     stats[:pair_reasons][:unsigned] += 1
    #   elsif [4, 5, 6].any?(((inst_history[1].encoding >> 12) & 0x7))
    #     stats[:pair_reasons][:unsigned] += 1
    #   elsif inst_history[0].ld_offset >= (inst_history[0].ldst_size*32)
    #     stats[:pair_reasons][:offset] += 1
    #   elsif inst_history[1].ld_offset >= (inst_history[1].ldst_size*32)
    #     stats[:pair_reasons][:offset] += 1
    #   elsif inst_history[0].rs1 < 8 || inst_history[0].rs1 > 15
    #     stats[:pair_reasons][:reg] += 1
    #   elsif inst_history[1].rs1 < 8 || inst_history[1].rs1 > 15
    #     stats[:pair_reasons][:reg] += 1
    #   elsif inst_history[0].rd < 8 || inst_history[0].rd > 15
    #     stats[:pair_reasons][:reg] += 1
    #   elsif inst_history[1].rd < 8 || inst_history[1].rd > 15
    #     stats[:pair_reasons][:reg] += 1
    #   elsif inst_history[0].ldst_size < 32
    #     stats[:pair_reasons][:size] += 1
    #   elsif inst_history[1].ldst_size < 32
    #     stats[:pair_reasons][:size] += 1
    #   else
    #     puts "#{inst_history[0].pc.to_s(16)} #{inst_history[0].rs1} #{inst_history[1].rs1}"
    #     stats[:pair_reasons][:other] += 1
    #   end
    # end
    # if inst_history[0].size == 16 && inst_history[1].size == 16
    #   lsp_savings += 0
    # elsif inst_history[0].size == 16 && inst_history[1].size == 32
    #   lsp_savings += 2
    # elsif inst_history[0].size == 32 && inst_history[1].size == 16
    #   lsp_savings += 2
    # else
    #   lsp_savings += 4
    # end
    # stats[:pair_addr_reg][inst_history[0].rs1] += 1
    # since this is consuming the current AND next instruction, increment the index by 2
    # so we don't pull in the same load twice
    inst_history.idx += 2
    stats[:est_inst_cnt] += 1
    stats[:est_size] += 4
  # elsif (n = ld_indexed?(inst_history, reg_history))
  #   nload_indexed += 1
  #   inst_history.idx += 1
  #   # already added n-1 instructions. take those away and add one, you get -(n-1) + 1 = -n + 2 = 2 - n
  #   stats[:est_inst_cnt] += 2 - n
  #   stats[:est_size] += 4
  # elsif (n = ld_reg_reg?(inst_history, reg_history))
  #   nload_reg_reg += 1
  #   inst_history.idx += 1
  #   stats[:est_inst_cnt] += 2 - n
  #   stats[:est_size] += 4
  # elsif (n = ld_pc_rel?(inst_history, reg_history))
  #   nload_pc_rel += 1
  #   inst_history.idx += 1
  #   stats[:est_inst_cnt] += 2 - n
  #   stats[:est_size] += 4

  # elsif (n = st_pair?(inst_history, options))
  #   nstore_pairs += 1
  #   stats[:st_pair_datatypes][inst_history[0].st_datatype] += 1
  #   stats[:st_pair_base][inst_history[0].rs1] += 1
  #   if inst_history[0].size == 16 && inst_history[1].size == 16
  #     lsp_savings += 0
  #   elsif inst_history[0].size == 16 && inst_history[1].size == 32
  #     lsp_savings += 2
  #   elsif inst_history[0].size == 32 && inst_history[1].size == 16
  #     lsp_savings += 2
  #   else
  #     lsp_savings += 4
  #   end
  #   stats[:pair_addr_reg][inst_history[0].rs1] += 1
  #   inst_history.idx += 2
  #   stats[:est_inst_cnt] += 1
  #   stats[:est_size] += 4
  # elsif (n = st_indexed?(inst_history, reg_history))
  #   nstore_indexed += 1
  #   inst_history.idx += 1
  #   stats[:est_inst_cnt] += 2 - n
  #   stats[:est_size] += 4
  # elsif (n = st_reg_reg?(inst_history, reg_history))
  #   nstore_reg_reg += 1
  #   inst_history.idx += 1
  #   # stats[:est_inst_cnt] += 2 - n
  #   stats[:est_size] -= reg_history[inst_history[0].rs1][0].size # remove add that we already counted
  #   stats[:est_size] += 4


  # elsif (n = long_j?(inst_history, reg_history))
  #   nj_long += 1
  #   inst_history.idx += 1
  #   # stats[:est_inst_cnt] += 2 - n
  #   stats[:est_inst_cnt] += 1
  #   stats[:est_size] += 4

  # elsif (imm_reg = branch_imm_cond?(inst_history, reg_history))
  #   nbr_cond_imm += 1
  #   inst_history.idx += 1
  #   # stats[:est_inst_cnt] += 2 - n
  #   stats[:est_size] -= reg_history[imm_reg][0].size # remove the imm gen that we already added
  #   stats[:est_size] += 4

  # elsif (n = double_mv?(inst_history))
  #   ndouble_mv += 1
  #   inst_history.idx += n
  #   stats[:est_inst_cnt] += 1
  #   stats[:est_size] += 4

  elsif (this_inst.is_load)
    stats[:unchanged][:ld] += 1
    stats[:est_inst_cnt] += 1
    # puts "#{inst_history.idx} #{(inst_history.idx*4 + section.header.sh_addr).to_s(16)} #{inst_history[0].to_s(16)}"

    stats[:est_size] += inst_history[0].size_bytes
    inst_history.idx += 1
  elsif (this_inst.is_store)
    stats[:unchanged][:st] += 1
    # if this_inst.rs1 == 2
    #   puts "#{inst_history.idx} #{(inst_history.idx*4 + section.header.sh_addr).to_s(16)} #{inst_history[0].encoding.to_s(16)}"
    # end
    stats[:est_size] += inst_history[0].size_bytes
    inst_history.idx += 1
    stats[:est_inst_cnt] += 1

  # elsif (ld_sp_inc?(inst_history))
  #   nsp_add += 1
  #   inst_history.idx += 1
  #   stats[:est_size] += 4
  #   # stats[:est_inst_cnt] += 1-1
  # elsif (st_sp_inc?(inst_history))
  #   nsp_add += 1
  #   inst_history.idx += 1
  #   stats[:est_size] += 4
  #   # stats[:est_inst_cnt] += 1-1
  # elsif long_literal?(inst_history, reg_history, options)
  #   nlong_literal += 1
  #   # puts "#{inst_history.idx} #{(inst_history.idx*4 + section.header.sh_addr).to_s(16)} #{inst_history[0].encoding.to_s(16)}"
  #   inst_history.idx += 1
  #   stats[:est_inst_cnt] += options[:long_literal] ? 1-1 : 1
  #   stats[:est_size] += 4
  else
    stats[:est_size] += inst_history[0].size_bytes
    inst_history.idx += 1
    stats[:est_inst_cnt] += 1
  end

  if options[:type] == :static && (this_inst.is_branch || this_inst.is_jal || this_inst.is_jalr)
    # clear the history on a branch
    reg_history.map! { |_| [] }
  elsif this_inst.has_dest?
    reg_history[this_inst.rd].prepend(this_inst)
    if reg_history[this_inst.rd].size >= 5
      reg_history[this_inst.rd].pop
    end
  end

end

table = Terminal::Table.new
#do |t|
#   t << ["nload_pairs", nload_pairs]
#   t << ["nload_reg_reg", nload_reg_reg]
#   t << ["nload_pc_rel", nload_pc_rel]
#   t << ["nload_indexed", nload_indexed]
#   t << ["nload_other", nloads]
#   t << :separator
#   t << ["nstore_pairs", nstore_pairs]
#   t << ["nstore_reg_reg", nstore_reg_reg]
#   t << ["nstore_indexed", nstore_indexed]
#   t << ["nstore_other", nstores]
#   t << :separator
#   t << ["nj_long", nj_long]
#   t << ["nbr_cond_imm", nbr_cond_imm]
#   t << :separator
#   t << ["ndouble_mv", ndouble_mv]
#   t << :separator
#   t << ["nlong_literal", nlong_literal]
#   t << :separator
#   t << ["lsp reduction (bytes)", lsp_savings]
#   t << [".text size (bytes)", section.data.size]
#   t << ["nsp_add", nsp_add]
#   lsp_w_prepost_savings = lsp_savings + 2*nsp_add
#   t << ["lsp reduction (%)", (1.0 - ((section.data.size.to_f-lsp_w_prepost_savings)/section.data.size.to_f))*100.0]
# end


# est_inst = ninsts - nload_pairs - nload_reg_reg - (2*nload_pc_rel) - (2*nload_indexed) - nstore_pairs - nstore_reg_reg - (2*nstore_indexed) - nj_long - nbr_cond_imm - nsp_add

# table << :separator
table << ["actual static instruction count", ninsts]
# table << ["nest_insts", est_inst]
table << ["estimated static instruction count", stats[:est_inst_cnt].value]
table << ["static inst ratio", stats[:est_inst_cnt].value.to_f / ninsts.to_f ]
table << ["est size (bytes)", stats[:est_size].value ]
table << ["actual size (bytes)", section.data.size ]
table << ["static size ratio", stats[:est_size].value.to_f / section.data.size.to_f ]

puts table

# bins = Array.new(4096/64, 0)
# pair_offsets.tally.each do |v, t| bins[v/64] += t end
# bins.each_with_index do |v, i| puts "#{i*64}-#{(i+1)*64 - 1} #{v}" end

# extract values from Stats
def strip_desc(stats)
  ret = {}
  stats.each do |k, v|
    if v.is_a?(Hash)
      ret[k] = strip_desc(v)
    elsif v.is_a?(Stat)
      ret[k] = v.value
    else
      raise "unexpected stat type"
    end
  end
  ret
end

unless options[:stat_output].nil?
  if options[:stat_output] == '-'
    pp strip_desc(stats)
  else
    File.write(options[:stat_output], YAML.dump(strip_desc(stats)))
  end
end
