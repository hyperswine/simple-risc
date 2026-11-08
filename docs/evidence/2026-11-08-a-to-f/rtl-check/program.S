
    .section .text.entry,"ax",@progbits
    .globl _start
    .option norelax
_start:
    li s8,0x80600000
    li s9,0x807ff000
    li s7,1
    lw t0,0(s9)
    addi t0,t0,1
    sw t0,0(s9)
    li t1,2
    beq t0,t1,recovered
    li t1,1
    bne t0,t1,failed

    # SD SPI: actual CPU MMIO handshake, synchronized external loopback,
    # mode-0 byte exchange, and capability register. DMA stays unmapped.
    li t3,0x10001000
    lw t0,12(t3)
    li t1,0x53445031
    bne t0,t1,failed
    li t0,0x301
    sw t0,8(t3)
    lw t1,8(t3)
    bne t0,t1,failed
    li t0,0x96
    sw t0,0(t3)
spi_wait:
    lw t0,4(t3)
    bnez t0,spi_wait
    lw t0,0(t3)
    li t1,0x96
    bne t0,t1,failed
    li t0,0x300
    sw t0,8(t3)
    lw t1,8(t3)
    bne t0,t1,failed

    # A known forced miss must count physical held clocks, not retire them.
    li s7,2
    li s0,0x80500000
    li a2,0x0200bff8
    lw a3,0(a2)
    csrr s2,mcycle
    csrr s3,minstret
    lw a0,0(s0)
    csrr t0,mcycle
    csrr t1,minstret
    sub t0,t0,s2
    sub t1,t1,s3
    sw t0,8(s8)
    sw t1,12(s8)
    lw t2,0(a2)
    sub t2,t2,a3
    sw t2,28(s8)
    li t3,1000
    bltu t2,t3,failed
    li t2,1000
    bltu t0,t2,failed
    li t2,64
    bgeu t1,t2,failed
    beqz t1,failed
    li t2,0x13579bdf
    bne a0,t2,failed

    # Ordered masked writes and immediate loads through the unified cache.
    li s7,3
    li s0,0x80200000
    li t0,0x11223344
    sw t0,0(s0)
    li t0,0xaa
    sb t0,1(s0)
    li t0,0xbbcc
    sh t0,2(s0)
    lw t1,0(s0)
    li t2,0xbbccaa44
    bne t1,t2,failed
    sw t1,16(s8)
    lbu t1,1(s0)
    li t2,0xaa
    bne t1,t2,failed
    lb t1,1(s0)
    li t2,-86
    bne t1,t2,failed
    lhu t1,2(s0)
    li t2,0xbbcc
    bne t1,t2,failed
    lh t1,2(s0)
    li t2,-17460
    bne t1,t2,failed

    # Identical cache indices at different high physical addresses must differ.
    li s7,4
    li s1,0x80400000
    li t0,0xdeadbeef
    sw t0,0(s1)
    lw t1,0(s0)
    li t2,0xbbccaa44
    bne t1,t2,failed
    lw t1,0(s1)
    bne t1,t0,failed
    li s1,0x807ffffc
    li t0,0xabcdef01
    sw t0,0(s1)
    lw t1,0(s1)
    bne t1,t0,failed

    # Execute freshly written and then patched instructions (including FENCE.I).
    li s7,5
    li s1,0x80201000
    li t0,0x02a00513
    sw t0,0(s1)
    li t0,0x00008067
    sw t0,4(s1)
    fence.i
    jalr ra,0(s1)
    li t0,42
    bne a0,t0,failed
    li t0,0x02b00513
    sw t0,0(s1)
    fence.i
    jalr ra,0(s1)
    li t0,43
    bne a0,t0,failed

    li s7,6
    li a0,-123456789
    li a1,12345
    mul t0,a0,a1
    li t1,0x261b6653
    bne t0,t1,failed
    mulh t0,a0,a1
    li t1,-355
    bne t0,t1,failed
    mulhsu t0,a0,a1
    bne t0,t1,failed
    mulhu t0,a0,a1
    li t1,11990
    bne t0,t1,failed
    div t0,a0,a1
    li t1,-10000
    bne t0,t1,failed
    rem t0,a0,a1
    li t1,-6789
    bne t0,t1,failed
    div t0,a0,zero
    li t1,-1
    bne t0,t1,failed
    rem t0,a0,zero
    bne t0,a0,failed
    li a0,0x80000000
    li a1,-1
    div t0,a0,a1
    bne t0,a0,failed
    rem t0,a0,a1
    bnez t0,failed

    li s7,7
    li t0,257
    li t2,0
square_loop:
    mul t1,t0,t0
    add t2,t2,t1
    addi t0,t0,-1
    bnez t0,square_loop
    li t1,5691265
    bne t2,t1,failed
    sw t2,20(s8)

    # Timer interrupts become due during eight forced cache misses. Mix
    # compressed branches and a straddling 32-bit instruction with load-use
    # dependencies. The handler must resume exactly once, preserving data;
    # stores on the branch's wrong path must never reach memory.
    li s7,10
    la t0,timer_handler
    csrw mtvec,t0
    li s11,0
    li a4,8
    li a5,0
    li s1,0x80510000
    li a6,0x10000
    li t0,0x5a5a1234
    sw t0,36(s8)
    li t0,128
    csrw mie,t0
    csrsi mstatus,8
timer_loop:
    li t3,0x0200bff8
    lw t0,0(t3)
    lw t1,4(t3)
    li t2,3000
    add t2,t0,t2
    sltu t0,t2,t0
    add t1,t1,t0
    li t3,0x02004000
    li t0,-1
    sw t0,0(t3)
    sw t1,4(t3)
    sw t2,0(t3)
    lw a0,0(s1)
    addi a0,a0,1
#ifdef RVC_GUEST
    .balign 4
    c.nop
    .option push
    .option norvc
    addi a0,a0,1
    .option pop
#else
    addi a0,a0,1
#endif
    li t0,2
    bne a0,t0,failed
    addi a5,a5,1
timer_wait:
    bltu s11,a5,timer_wait
    bne s11,a5,failed
    beq a0,t0,timer_taken
    sw zero,36(s8)
timer_taken:
    add s1,s1,a6
    addi a4,a4,-1
    bnez a4,timer_loop
    csrci mstatus,8
    csrw mie,zero
    sw s11,32(s8)
    lw t0,36(s8)
    li t1,0x5a5a1234
    bne t0,t1,failed

    # A private handler checks precise cause and trap value, then resumes.
    li s7,8
    la t0,trap_handler
    csrw mtvec,t0
    li s5,0
    li s10,4
    li s4,11
    li s6,0
    ecall
    li s4,2
    li s6,-1
    .word 0xffffffff
    li s4,4
    li s6,0x80200001
    .option push
    .option norvc
    lw a0,1(s0)
    .option pop
#ifndef RVC_GUEST
    li s4,0
    la t0,aligned_target
    addi t0,t0,2
    mv s6,t0
    jalr zero,0(t0)
    li t0,4
#else
    # A reserved compressed encoding must preserve raw mtval and resume at pc+2.
    li s4,2
    li s6,0
    li s10,2
    .half 0x0000
    li s10,4
    li t0,4
#endif
    bne s5,t0,failed
    sw s5,24(s8)
    csrw mtvec,zero

    # One externally visible store must be accepted exactly once, even when
    # its request is held. A younger store after the jump must be cancelled.
    li t4,0x80600100
    li t5,0x71e77e55
    .option push
    .option norvc
    .balign 4
    # Fill the four-entry write queue faster than the delayed backend drains
    # it, so the owned request must survive write-full backpressure as well.
    .rept 8
    sw t5,-4(t4)
    .endr
effect_once:
    sw t5,0(t4)
    sw t5,4(t4)
    sw t5,8(t4)
    sw t5,12(t4)
    sw t5,16(t4)
    sw t5,20(t4)
    sw t5,24(t4)
    sw t5,28(t4)
effect_padding:
    .word 0x00000013
effect_skip:
    j effect_join
    sw t5,32(t4)
effect_join:
    .option pop

    li t0,0x10000000
    li t1,80
uart_pass:
    lw t2,4(t0)
    andi t2,t2,1
    beqz t2,uart_pass
    sb t1,0(t0)
    li t0,0x600d0001
    sw t0,0(s8)
    # The bench delays this line long enough to receive an entire Ctrl-C byte.
    li s0,0x80300000
    li s1,0x80301000
wait_for_break:
    lw t0,0(s0)
    lw t1,0(s1)
    j wait_for_break

recovered:
    li s7,9
    lw t0,0(s8)
    li t1,0x600d0001
    bne t0,t1,failed
    lw t0,16(s8)
    li t1,0xbbccaa44
    bne t0,t1,failed
    li t0,0x10000000
    li t1,82
uart_recovery:
    lw t2,4(t0)
    andi t2,t2,1
    beqz t2,uart_recovery
    sb t1,0(t0)
    li t0,0x600d0002
    sw t0,0(s8)
park:
    j park

    .balign 4
aligned_target:
    j failed
    .balign 4
trap_handler:
    csrr t0,mcause
    bne t0,s4,failed
    csrr t0,mtval
    bne t0,s6,failed
    addi s5,s5,1
    csrr t0,mepc
    add t0,t0,s10
    csrw mepc,t0
    mret
    .balign 4
timer_handler:
    csrr s2,mcause
    li s3,0x80000007
    bne s2,s3,failed
    csrr s2,mepc
#ifdef RVC_GUEST
    andi s2,s2,1
#else
    andi s2,s2,3
#endif
    bnez s2,failed
    li s3,0x02004000
    li s2,-1
    sw s2,0(s3)
    sw s2,4(s3)
    addi s11,s11,1
    mret
failed:
    sw s7,4(s8)
    li t0,0xbad00001
    sw t0,0(s8)
    j park
