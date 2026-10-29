
OUTPUT_ARCH(riscv)
ENTRY(_start)
MEMORY { RAM (rwx) : ORIGIN = 0x80000000, LENGTH = 8M }
SECTIONS {
  .text : { KEEP(*(.text.entry)) *(.text .text.*) } > RAM
  .rodata : { *(.rodata .rodata.*) } > RAM
  .data : { *(.data .data.* .sdata .sdata.*) } > RAM
  .bss : { *(.bss .bss.* .sbss .sbss.* COMMON) } > RAM
}
