.text
.globl main
main:
    li   t0, 0x10000000
    li   t1, 1048576
    li   t2, 0x5A
.L_loop:
    sb   t2, 0(t0)
    addi t0, t0, 1
    addi t1, t1, -1
    bnez t1, .L_loop

    li   a7, 10
    ecall
