.text
.globl main
main:
    li   t0, 10000000
.L_loop:
    addi t0, t0, -1
    bnez t0, .L_loop

    li   a7, 10
    ecall
