
    .section .text.entry,"ax",@progbits
    .globl _start
_start:
    lui t0,0x10000
    li t1,76
    sb t1,0(t0)
    ebreak
