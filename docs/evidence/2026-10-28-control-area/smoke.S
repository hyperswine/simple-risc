 .section .text.entry,"ax",@progbits
 .globl _start
_start:
 li s0,0x80040000
 li s1,0x80048000
 li s2,0x80050000
 li t0,17
 sw t0,0(s0)
 li t0,34
 sw t0,0(s1)
 li t0,51
 sw t0,0(s2)
 li s3,12
again:
 lw t0,0(s0)
 li t1,17
 bne t0,t1,failed
 lw t0,0(s1)
 li t1,34
 bne t0,t1,failed
 lw t0,0(s0)
 li t1,17
 bne t0,t1,failed
 lw t0,0(s2)
 li t1,51
 bne t0,t1,failed
 lw t0,0(s1)
 li t1,34
 bne t0,t1,failed
 addi s3,s3,-1
 bnez s3,again
 la s0,success
 j print
failed:
 la s0,failure
print:
 li s1,0x10000000
next:
 lbu t0,0(s0)
 beqz t0,stop
 sb t0,0(s1)
 addi s0,s0,1
 j next
stop:
 j stop
success: .asciz "\nFPR EXIT 0\n"
failure: .asciz "FPR EXIT 1\n"
