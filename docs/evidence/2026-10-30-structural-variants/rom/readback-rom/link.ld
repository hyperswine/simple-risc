/* The boot ROM: 2 KiB at address 0, code and read-only data only.
 * Words 508..511 (0x7f0..0x7fc) hold CPU/memory clocks and the build ID. */
OUTPUT_ARCH(riscv)
ENTRY(_start)
PROVIDE(rom_meta = 0x000007f0);
MEMORY { ROM (rx) : ORIGIN = 0x00000000, LENGTH = 2032 }
SECTIONS {
  .text : { KEEP(*(.text.entry)) *(.text .text.*) *(.rodata .rodata.* .srodata .srodata.*) } > ROM
  .data : { *(.data .data.* .sdata .sdata.*) } > ROM
  .bss : { *(.bss .bss.* .sbss .sbss.* COMMON) } > ROM
  ASSERT(SIZEOF(.data) == 0 && SIZEOF(.bss) == 0, "the boot ROM cannot have writable data")
}
