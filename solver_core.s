# ==============================================================================
# 2x2x2 Rubik's Cube Optimal Solver (Meet-in-the-Middle IDA* + 6-Step Cache)
# Target: RISC-V RV32I Base Integer Instruction Set (for Ripes Simulator)
# Memory Footprint: ~87 KiB (well under 128 KiB memory budget)
# ==============================================================================

.data
.globl input_state
input_state:
    .string "21345671111111"    # Default sample test state (11-move God's number)

# Static tables for 90-degree turns
map_p:
    .byte 1, 4, 2, 0, 3, 5, 6  # Face R (0)
    .byte 0, 1, 2, 4, 5, 6, 3  # Face B (1)
    .byte 0, 2, 5, 3, 1, 4, 6  # Face D (2)

map_o:
    .byte 1, 2, 0, 2, 1, 0, 0  # Face R (0)
    .byte 0, 0, 0, 1, 2, 1, 2  # Face B (1)
    .byte 0, 0, 0, 0, 0, 0, 0  # Face D (2)

# Symmetry D3 permutation and de-mapping tables
slot_from_k1:
    .byte 2, 5, 6, 1, 4, 3, 0
piece_map_k1:
    .byte 6, 3, 0, 5, 4, 1, 2

slot_from_mirror:
    .byte 2, 1, 0, 5, 4, 3, 6
piece_map_mirror:
    .byte 2, 1, 0, 5, 4, 3, 6

# Symmetry move de-mapping table: inv_move_map[k * 9 + m_canon] -> m_real
inv_move_map:
    .byte 0, 1, 2, 3, 4, 5, 6, 7, 8  # k = 0: identity
    .byte 6, 7, 8, 0, 1, 2, 3, 4, 5  # k = 1: rot120
    .byte 3, 4, 5, 6, 7, 8, 0, 1, 2  # k = 2: rot240
    .byte 8, 7, 6, 5, 4, 3, 2, 1, 0  # k = 3: mirror
    .byte 2, 1, 0, 8, 7, 6, 5, 4, 3  # k = 4: mirror + rot120
    .byte 5, 4, 3, 2, 1, 0, 8, 7, 6  # k = 5: mirror + rot240

# Runtime scratch memory
.align 2
start_state:   .zero 16    # p[0..6] (7 B), o[0..6] (7 B), 2 B pad
next_state:    .zero 16
canon_state:   .zero 16
tr1_state:     .zero 16
tr2_state:     .zero 16
tr3_state:     .zero 16
tr4_state:     .zero 16
tr5_state:     .zero 16
move_scratch:  .zero 16
unpack_cur:    .zero 16
unpack_canon:  .zero 16
unpack_temp:   .zero 16

# IDA* Search Stack: 8 frames, each 20 bytes
# Frame layout:
#   offset  0: state (16 bytes)
#   offset 16: last_face (1 byte: 0=R, 1=B, 2=D, 3=None)
#   offset 17: move_idx  (1 byte: 0..8)
#   offset 18: pad (2 bytes)
.align 2
search_stack:   .zero 160
solution_moves: .zero 16
sol_len:        .4byte 0

.text
.globl main

# ==============================================================================
# MAIN ENTRY POINT
# ==============================================================================
main:
    # Set up stack pointer (if not already initialized by environment)
    # la sp, 0x7FFFFFF0 (in Ripes sp is initialized)

    # 1. Parse input string into start_state
    la a0, input_state
    la a1, start_state
    jal ra, parse_input

    # 2. Check if already solved (h == 0)
    la a0, start_state
    jal ra, get_h
    beqz a0, main_already_solved

    # 3. Level 0 cache check
    la a0, start_state
    la a1, canon_state
    jal ra, canonicalize
    jal ra, lookup_cache
    # a0 = found (0 or 1), a1 = d_remain, a2 = next_move
    beqz a0, main_start_ida

    # Hit cache at level 0!
    la t0, sol_len
    sw a1, 0(t0)               # sol_len = d_remain
    mv a2, a1                  # d_remain
    li a1, 0                   # start_pos = 0
    la a0, start_state
    jal ra, unpack_cache
    j main_print_solution

main_already_solved:
    la t0, sol_len
    sw x0, 0(t0)
    j main_print_solution

main_start_ida:
    # 4. Run Meet-in-the-Middle IDA* solver
    jal ra, solve_mitm

main_print_solution:
    # 5. Print solution moves matching standard format
    la t0, sol_len
    lw s0, 0(t0)               # sol_len
    li s1, 0                   # i = 0

print_loop:
    bge s1, s0, print_newline

    # Print space if i > 0
    beqz s1, print_move_char
    li a0, 32                  # ' '
    li a7, 11
    ecall

print_move_char:
    la t0, solution_moves
    add t0, t0, s1
    lbu t1, 0(t0)              # move_idx (0..8)

    li t2, 3
    blt t1, t2, .L_pface_R
    li t2, 6
    blt t1, t2, .L_pface_B
    li a0, 68                  # 'D'
    addi t3, t1, -6            # suffix = move_idx - 6
    j .L_pface_print
.L_pface_R:
    li a0, 82                  # 'R'
    mv t3, t1                  # suffix = move_idx
    j .L_pface_print
.L_pface_B:
    li a0, 66                  # 'B'
    addi t3, t1, -3            # suffix = move_idx - 3

.L_pface_print:
    li a7, 11
    ecall                      # print face character

    # Suffix: 0 = none, 1 = '2', 2 = '\''
    beqz t3, print_next_move
    li t2, 1
    beq t3, t2, .L_psuf_2
    li a0, 39                  # '\''
    li a7, 11
    ecall
    j print_next_move
.L_psuf_2:
    li a0, 50                  # '2'
    li a7, 11
    ecall

print_next_move:
    addi s1, s1, 1
    j print_loop

print_newline:
    li a0, 10                  # '\n'
    li a7, 11
    ecall

    # Exit program
    li a7, 10
    ecall

# ==============================================================================
# SUBROUTINE: parse_input(a0 = str_ptr, a1 = state_ptr)
# ==============================================================================
parse_input:
    li t0, 0           # i = 0
.L_parse_p:
    add t1, a0, t0
    lbu t2, 0(t1)
    addi t2, t2, -49   # - '1'
    add t3, a1, t0
    sb t2, 0(t3)
    addi t0, t0, 1
    li t4, 7
    blt t0, t4, .L_parse_p

    li t0, 0           # i = 0
.L_parse_o:
    addi t1, t0, 7
    add t1, a0, t1
    lbu t2, 0(t1)
    addi t2, t2, -49   # - '1'
    addi t3, a1, 7
    add t3, t3, t0
    sb t2, 0(t3)
    addi t0, t0, 1
    li t4, 7
    blt t0, t4, .L_parse_o
    ret

# ==============================================================================
# SUBROUTINE: apply_turn_90(a0 = src_ptr, a1 = f, a2 = dst_ptr)
# ==============================================================================
apply_turn_90:
    slli t0, a1, 3
    sub t0, t0, a1     # f * 7
    la t1, map_p
    add t1, t1, t0     # p_map
    la t2, map_o
    add t2, t2, t0     # o_map

    li t3, 0           # i = 0
.L_turn_loop:
    add t4, t1, t3
    lbu t4, 0(t4)      # j = map_p[f][i]

    add t5, a0, t4
    lbu t5, 0(t5)      # src.p[j]
    add t6, a2, t3
    sb t5, 0(t6)       # dst.p[i]

    addi t5, a0, 7
    add t5, t5, t4
    lbu t5, 0(t5)      # src.o[j]
    add t6, t2, t3
    lbu t6, 0(t6)      # map_o[f][i]
    add t5, t5, t6     # sum
    li t6, 3
    blt t5, t6, .L_turn_no_sub
    addi t5, t5, -3
.L_turn_no_sub:
    addi t6, a2, 7
    add t6, t6, t3
    sb t5, 0(t6)       # dst.o[i]

    addi t3, t3, 1
    li t4, 7
    blt t3, t4, .L_turn_loop
    ret

# ==============================================================================
# SUBROUTINE: apply_move(a0 = src_ptr, a1 = m, a2 = dst_ptr)
# ==============================================================================
apply_move:
    addi sp, sp, -32
    sw ra, 28(sp)
    sw s0, 24(sp)
    sw s1, 20(sp)
    sw s2, 16(sp)
    sw s3, 12(sp)
    sw s4, 8(sp)

    mv s0, a0          # src_ptr
    mv s1, a1          # m
    mv s2, a2          # dst_ptr

    li t0, 3
    blt s1, t0, .L_mf_0
    li t0, 6
    blt s1, t0, .L_mf_1
    li s3, 2           # f = 2 (D)
    addi s4, s1, -5    # count = m - 6 + 1 = m - 5
    j .L_m_turn_start
.L_mf_0:
    li s3, 0           # f = 0 (R)
    addi s4, s1, 1     # count = m + 1
    j .L_m_turn_start
.L_mf_1:
    li s3, 1           # f = 1 (B)
    addi s4, s1, -2    # count = m - 3 + 1 = m - 2

.L_m_turn_start:
    mv a0, s0
    mv a1, s3
    mv a2, s2
    jal ra, apply_turn_90
    addi s4, s4, -1
    beqz s4, .L_m_done

.L_m_loop:
    la t0, move_scratch
    lw t1, 0(s2)
    sw t1, 0(t0)
    lw t1, 4(s2)
    sw t1, 4(t0)
    lw t1, 8(s2)
    sw t1, 8(t0)
    lw t1, 12(s2)
    sw t1, 12(t0)

    mv a0, t0
    mv a1, s3
    mv a2, s2
    jal ra, apply_turn_90
    addi s4, s4, -1
    bnez s4, .L_m_loop

.L_m_done:
    lw s4, 8(sp)
    lw s3, 12(sp)
    lw s2, 16(sp)
    lw s1, 20(sp)
    lw s0, 24(sp)
    lw ra, 28(sp)
    addi sp, sp, 32
    ret

# ==============================================================================
# SUBROUTINE: get_p_rank(a0 = p_ptr) -> a0 = rank
# ==============================================================================
get_p_rank:
    li t0, 0           # rank = 0
    li t1, 0           # i = 0

.L_prank_loop_i:
    add t2, a0, t1
    lbu t2, 0(t2)      # p[i]
    li t3, 0           # n = 0
    addi t4, t1, 1     # j = i + 1

.L_prank_loop_j:
    li t5, 7
    bge t4, t5, .L_prank_j_done
    add t6, a0, t4
    lbu t6, 0(t6)      # p[j]
    bge t6, t2, .L_prank_j_next
    addi t3, t3, 1     # n++
.L_prank_j_next:
    addi t4, t4, 1
    j .L_prank_loop_j

.L_prank_j_done:
    li t5, 7
    sub t5, t5, t1     # 7 - i
    li a1, 7
    beq t5, a1, .L_mul_7
    li a1, 6
    beq t5, a1, .L_mul_6
    li a1, 5
    beq t5, a1, .L_mul_5
    li a1, 4
    beq t5, a1, .L_mul_4
    li a1, 3
    beq t5, a1, .L_mul_3
    li a1, 2
    beq t5, a1, .L_mul_2
    j .L_mul_done

.L_mul_7:
    slli a1, t0, 3
    sub t0, a1, t0
    j .L_mul_done
.L_mul_6:
    slli a1, t0, 3
    slli a2, t0, 1
    sub t0, a1, a2
    j .L_mul_done
.L_mul_5:
    slli a1, t0, 2
    add t0, a1, t0
    j .L_mul_done
.L_mul_4:
    slli t0, t0, 2
    j .L_mul_done
.L_mul_3:
    slli a1, t0, 1
    add t0, a1, t0
    j .L_mul_done
.L_mul_2:
    slli t0, t0, 1
    j .L_mul_done

.L_mul_done:
    add t0, t0, t3     # rank += n
    addi t1, t1, 1     # i++
    li t5, 7
    blt t1, t5, .L_prank_loop_i

    mv a0, t0
    ret

# ==============================================================================
# SUBROUTINE: get_o_rank(a0 = o_ptr) -> a0 = rank
# ==============================================================================
get_o_rank:
    li t0, 0           # rank = 0
    li t1, 0           # i = 0
.L_orank_loop:
    add t2, a0, t1
    lbu t2, 0(t2)      # o[i]
    slli t3, t0, 1
    add t0, t3, t0     # rank * 3
    add t0, t0, t2     # rank * 3 + o[i]
    addi t1, t1, 1
    li t3, 6
    blt t1, t3, .L_orank_loop
    mv a0, t0
    ret

# ==============================================================================
# SUBROUTINE: rank_state(a0 = state_ptr) -> a0 = composite rank
# ==============================================================================
rank_state:
    addi sp, sp, -16
    sw ra, 12(sp)
    sw s0, 8(sp)
    sw s1, 4(sp)

    mv s0, a0

    mv a0, s0
    jal ra, get_p_rank
    mv s1, a0          # s1 = p_rank

    addi a0, s0, 7
    jal ra, get_o_rank # a0 = o_rank

    slli t0, s1, 3
    add t0, t0, s1     # 9 * s1
    slli t1, t0, 3
    add t1, t1, t0     # 81 * s1
    slli t2, t1, 3
    add t2, t2, t1     # 729 * s1

    add a0, t2, a0

    lw s1, 4(sp)
    lw s0, 8(sp)
    lw ra, 12(sp)
    addi sp, sp, 16
    ret

# ==============================================================================
# SUBROUTINE: get_h(a0 = state_ptr) -> a0 = heuristic
# ==============================================================================
get_h:
    addi sp, sp, -16
    sw ra, 12(sp)
    sw s0, 8(sp)
    sw s1, 4(sp)

    mv s0, a0

    # o_pdb lookup
    addi a0, s0, 7
    jal ra, get_o_rank
    la t0, o_pdb
    add t0, t0, a0
    lbu s1, 0(t0)      # s1 = h_o

    # p_pdb lookup
    mv a0, s0
    jal ra, get_p_rank
    la t0, p_pdb
    add t0, t0, a0
    lbu t1, 0(t0)      # t1 = h_p

    # a0 = max(h_o, h_p)
    bge s1, t1, .L_h_is_o
    mv a0, t1
    j .L_h_done
.L_h_is_o:
    mv a0, s1

.L_h_done:
    lw s1, 4(sp)
    lw s0, 8(sp)
    lw ra, 12(sp)
    addi sp, sp, 16
    ret

# ==============================================================================
# SUBROUTINE: transform_k1(a0 = src_ptr, a1 = dst_ptr)
# ==============================================================================
transform_k1:
    la t0, slot_from_k1
    la t1, piece_map_k1
    li t2, 0            # j = 0

.L_k1_loop:
    add t3, t0, t2
    lbu t3, 0(t3)       # from = slot_from_k1[j]

    add t4, a0, t3
    lbu t4, 0(t4)       # old_p = src.p[from]

    addi t5, a0, 7
    add t5, t5, t3
    lbu t5, 0(t5)       # old_o = src.o[from]

    add t6, t1, t4
    lbu t6, 0(t6)       # piece_map_k1[old_p]
    add a3, a1, t2
    sb t6, 0(a3)        # dst.p[j] = new_p

    andi a3, t2, 1      # j & 1
    andi a4, t4, 1      # old_p & 1
    beqz a3, .L_k1_even_j
    # odd j:
    bnez a4, .L_k1_odd_p_odd
    li a5, 2            # odd j, even p -> offset 2
    j .L_k1_off_done
.L_k1_odd_p_odd:
    li a5, 0            # odd j, odd p -> offset 0
    j .L_k1_off_done

.L_k1_even_j:
    bnez a4, .L_k1_even_p_odd
    li a5, 0            # even j, even p -> offset 0
    j .L_k1_off_done
.L_k1_even_p_odd:
    li a5, 1            # even j, odd p -> offset 1

.L_k1_off_done:
    add t5, t5, a5
    li a5, 3
    blt t5, a5, .L_k1_no_sub
    addi t5, t5, -3
.L_k1_no_sub:
    addi a3, a1, 7
    add a3, a3, t2
    sb t5, 0(a3)        # dst.o[j] = no

    addi t2, t2, 1
    li a3, 7
    blt t2, a3, .L_k1_loop
    ret

# ==============================================================================
# SUBROUTINE: transform_mirror(a0 = src_ptr, a1 = dst_ptr)
# ==============================================================================
transform_mirror:
    la t0, slot_from_mirror
    la t1, piece_map_mirror
    li t2, 0            # j = 0

.L_m_loop_mir:
    add t3, t0, t2
    lbu t3, 0(t3)       # from = slot_from_mirror[j]

    add t4, a0, t3
    lbu t4, 0(t4)       # old_p = src.p[from]

    addi t5, a0, 7
    add t5, t5, t3
    lbu t5, 0(t5)       # old_o = src.o[from]

    add t6, t1, t4
    lbu t6, 0(t6)       # piece_map_mirror[old_p]
    add a3, a1, t2
    sb t6, 0(a3)        # dst.p[j] = new_p

    andi a3, t2, 1      # j & 1
    andi a4, t4, 1      # old_p & 1
    beqz a3, .L_m_even_j
    # odd j:
    bnez a4, .L_m_odd_p_odd
    li a5, 2            # odd j, even p -> offset 2
    j .L_m_off_done
.L_m_odd_p_odd:
    li a5, 0            # odd j, odd p -> offset 0
    j .L_m_off_done

.L_m_even_j:
    bnez a4, .L_m_even_p_odd
    li a5, 0            # even j, even p -> offset 0
    j .L_m_off_done
.L_m_even_p_odd:
    li a5, 1            # even j, odd p -> offset 1

.L_m_off_done:
    # new_o = (3 - old_o + offset) % 3
    li a3, 3
    sub a3, a3, t5      # 3 - old_o
    add t5, a3, a5      # 3 - old_o + offset
    li a5, 3
    blt t5, a5, .L_m_no_sub_mir
    addi t5, t5, -3
.L_m_no_sub_mir:
    addi a3, a1, 7
    add a3, a3, t2
    sb t5, 0(a3)        # dst.o[j] = no

    addi t2, t2, 1
    li a3, 7
    blt t2, a3, .L_m_loop_mir
    ret

# ==============================================================================
# SUBROUTINE: canonicalize(a0 = src_ptr, a1 = out_canon_ptr) -> a0 = min_rank, a1 = k
# ==============================================================================
canonicalize:
    addi sp, sp, -32
    sw ra, 28(sp)
    sw s0, 24(sp)
    sw s1, 20(sp)
    sw s2, 16(sp)
    sw s3, 12(sp)
    sw s4, 8(sp)

    mv s0, a0          # src_ptr (tr0)
    mv s1, a1          # out_canon_ptr

    # 1. Rank of tr0 (s0)
    mv a0, s0
    jal ra, rank_state
    mv s2, a0          # min_r = r0
    li s3, 0           # best_k = 0
    mv s4, s0          # best_state_ptr = tr0

    # 2. tr1 = R120(tr0)
    mv a0, s0
    la a1, tr1_state
    jal ra, transform_k1
    la a0, tr1_state
    jal ra, rank_state # a0 = r1
    bge a0, s2, .L_check_tr2
    mv s2, a0          # min_r = r1
    li s3, 1           # best_k = 1
    la s4, tr1_state

.L_check_tr2:
    # 3. tr2 = R120(tr1)
    la a0, tr1_state
    la a1, tr2_state
    jal ra, transform_k1
    la a0, tr2_state
    jal ra, rank_state # a0 = r2
    bge a0, s2, .L_check_tr3
    mv s2, a0          # min_r = r2
    li s3, 2           # best_k = 2
    la s4, tr2_state

.L_check_tr3:
    # 4. tr3 = Mirror(tr0)
    mv a0, s0
    la a1, tr3_state
    jal ra, transform_mirror
    la a0, tr3_state
    jal ra, rank_state # a0 = r3
    bge a0, s2, .L_check_tr4
    mv s2, a0          # min_r = r3
    li s3, 3           # best_k = 3
    la s4, tr3_state

.L_check_tr4:
    # 5. tr4 = R120(tr3)
    la a0, tr3_state
    la a1, tr4_state
    jal ra, transform_k1
    la a0, tr4_state
    jal ra, rank_state # a0 = r4
    bge a0, s2, .L_check_tr5
    mv s2, a0          # min_r = r4
    li s3, 4           # best_k = 4
    la s4, tr4_state

.L_check_tr5:
    # 6. tr5 = R120(tr4)
    la a0, tr4_state
    la a1, tr5_state
    jal ra, transform_k1
    la a0, tr5_state
    jal ra, rank_state # a0 = r5
    bge a0, s2, .L_canon_copy
    mv s2, a0          # min_r = r5
    li s3, 5           # best_k = 5
    la s4, tr5_state

.L_canon_copy:
    # Copy best_state (16 bytes) to out_canon_ptr
    lw t0, 0(s4)
    sw t0, 0(s1)
    lw t0, 4(s4)
    sw t0, 4(s1)
    lw t0, 8(s4)
    sw t0, 8(s1)
    lw t0, 12(s4)
    sw t0, 12(s1)

    mv a0, s2          # return min_rank
    mv a1, s3          # return best_k

    lw s4, 8(sp)
    lw s3, 12(sp)
    lw s2, 16(sp)
    lw s1, 20(sp)
    lw s0, 24(sp)
    lw ra, 28(sp)
    addi sp, sp, 32
    ret

# ==============================================================================
# SUBROUTINE: lookup_cache(a0 = target_id) -> a0 = found, a1 = d_remain, a2 = next_move
# ==============================================================================
lookup_cache:
    li t0, 0            # low = 0
    la t1, short_cache_size
    lw t1, 0(t1)
    addi t1, t1, -1     # high = short_cache_size - 1
    la t2, short_cache

.L_cbin_loop:
    bgt t0, t1, .L_cbin_miss
    add t3, t0, t1
    srai t3, t3, 1      # mid = (low + high) >> 1
    slli t4, t3, 2      # mid * 4
    add t4, t2, t4
    lw t4, 0(t4)        # entry
    srli t5, t4, 7      # id = entry >> 7

    beq t5, a0, .L_cbin_hit
    blt t5, a0, .L_cbin_right

    addi t1, t3, -1     # high = mid - 1
    j .L_cbin_loop

.L_cbin_right:
    addi t0, t3, 1      # low = mid + 1
    j .L_cbin_loop

.L_cbin_hit:
    li a0, 1            # found = 1
    srli a1, t4, 4
    andi a1, a1, 7      # d_remain = (entry >> 4) & 7
    andi a2, t4, 15     # next_move = entry & 0xF
    ret

.L_cbin_miss:
    li a0, 0
    li a1, 0
    li a2, 0
    ret

# ==============================================================================
# SUBROUTINE: demap_move(a0 = m_canon, a1 = k) -> a0 = m_real
# ==============================================================================
demap_move:
    # offset = k * 9 + m_canon = (k << 3) + k + m_canon
    slli t0, a1, 3
    add t0, t0, a1
    add t0, t0, a0
    la t1, inv_move_map
    add t1, t1, t0
    lbu a0, 0(t1)
    ret

# ==============================================================================
# SUBROUTINE: unpack_cache(a0 = state_ptr, a1 = start_pos, a2 = d_remain)
# ==============================================================================
unpack_cache:
    addi sp, sp, -32
    sw ra, 28(sp)
    sw s0, 24(sp)
    sw s1, 20(sp)
    sw s2, 16(sp)
    sw s3, 12(sp)

    mv s0, a1          # cur_pos = start_pos
    mv s1, a2          # d_remain
    mv s2, a0          # src_state_ptr

    # Copy src_state to unpack_cur
    la t0, unpack_cur
    lw t1, 0(s2)
    sw t1, 0(t0)
    lw t1, 4(s2)
    sw t1, 4(t0)
    lw t1, 8(s2)
    sw t1, 8(t0)
    lw t1, 12(s2)
    sw t1, 12(t0)

    li s3, 0           # step = 0

.L_unpack_loop:
    bge s3, s1, .L_unpack_done

    la a0, unpack_cur
    la a1, unpack_canon
    jal ra, canonicalize
    # a0 = canon_id, a1 = k
    mv t0, a1          # t0 = k

    addi sp, sp, -8
    sw t0, 4(sp)       # save k
    jal ra, lookup_cache
    # a0 = found, a1 = d_rem, a2 = m_canon
    lw t0, 4(sp)
    addi sp, sp, 8

    # demap_move(m_canon = a2, k = t0)
    mv a0, a2
    mv a1, t0
    jal ra, demap_move
    # a0 = m_real

    # Store into solution_moves[cur_pos]
    la t0, solution_moves
    add t0, t0, s0
    sb a0, 0(t0)

    # Apply move to unpack_cur:
    # 1. Copy unpack_cur to unpack_temp
    la t1, unpack_temp
    la t2, unpack_cur
    lw t3, 0(t2)
    sw t3, 0(t1)
    lw t3, 4(t2)
    sw t3, 4(t1)
    lw t3, 8(t2)
    sw t3, 8(t1)
    lw t3, 12(t2)
    sw t3, 12(t1)

    # 2. apply_move(unpack_temp, m_real, unpack_cur)
    la t0, solution_moves
    add t0, t0, s0
    lbu a1, 0(t0)      # m_real
    la a0, unpack_temp
    la a2, unpack_cur
    jal ra, apply_move

    addi s0, s0, 1     # cur_pos++
    addi s3, s3, 1     # step++
    j .L_unpack_loop

.L_unpack_done:
    lw s3, 12(sp)
    lw s2, 16(sp)
    lw s1, 20(sp)
    lw s0, 24(sp)
    lw ra, 28(sp)
    addi sp, sp, 32
    ret

# ==============================================================================
# SUBROUTINE: solve_mitm() -> returns when solution is placed in solution_moves
# ==============================================================================
solve_mitm:
    addi sp, sp, -64
    sw ra, 60(sp)
    sw s0, 56(sp)
    sw s1, 52(sp)
    sw s2, 48(sp)
    sw s3, 44(sp)
    sw s4, 40(sp)
    sw s5, 36(sp)
    sw s6, 32(sp)
    sw s7, 28(sp)

    # Initial threshold = max(h(start), 7)
    la a0, start_state
    jal ra, get_h
    li t0, 7
    bge a0, t0, .L_thresh_init
    li a0, 7
.L_thresh_init:
    mv s0, a0          # s0 = threshold

.L_ida_outer_loop:
    li t0, 11
    bgt s0, t0, .L_ida_fail

    li s1, 99          # s1 = next_threshold = 99
    li s2, 0           # s2 = top = 0

    # Initialize stack[0]:
    # stack[0].state = start_state
    # stack[0].last_face = 3
    # stack[0].move_idx = 0
    la t0, search_stack
    la t1, start_state
    lw t2, 0(t1)
    sw t2, 0(t0)
    lw t2, 4(t1)
    sw t2, 4(t0)
    lw t2, 8(t1)
    sw t2, 8(t0)
    lw t2, 12(t1)
    sw t2, 12(t0)
    li t2, 3
    sb t2, 16(t0)      # last_face = 3
    sb x0, 17(t0)      # move_idx = 0

.L_ida_inner_loop:
    bltz s2, .L_ida_next_threshold # top < 0 -> deepen threshold

    # Frame address = search_stack + top * 20
    # 20 * top = (top << 4) + (top << 2) = 16*top + 4*top
    slli t0, s2, 4
    slli t1, s2, 2
    add t0, t0, t1
    la t1, search_stack
    add s3, t1, t0     # s3 = frame_ptr

    lbu s4, 17(s3)     # s4 = m = frame.move_idx
    li t0, 9
    blt s4, t0, .L_ida_check_move

    # Backtrace: top--
    addi s2, s2, -1
    bltz s2, .L_ida_inner_loop
    # frame_prev.move_idx++
    slli t0, s2, 4
    slli t1, s2, 2
    add t0, t0, t1
    la t1, search_stack
    add t0, t1, t0
    lbu t2, 17(t0)
    addi t2, t2, 1
    sb t2, 17(t0)
    j .L_ida_inner_loop

.L_ida_check_move:
    # Face of move m
    li t0, 3
    blt s4, t0, .L_f_0
    li t0, 6
    blt s4, t0, .L_f_1
    li s5, 2           # f = 2
    j .L_f_check
.L_f_0:
    li s5, 0           # f = 0
    j .L_f_check
.L_f_1:
    li s5, 1           # f = 1

.L_f_check:
    lbu t0, 16(s3)     # last_face
    bne s5, t0, .L_ida_try_step

    # Same face rotate -> skip
    addi s4, s4, 1
    sb s4, 17(s3)
    j .L_ida_inner_loop

.L_ida_try_step:
    # next_s = apply_move(frame.state, m)
    mv a0, s3          # frame.state
    mv a1, s4          # m
    la a2, next_state
    jal ra, apply_move

    # h = get_h(next_state)
    la a0, next_state
    jal ra, get_h
    mv s6, a0          # s6 = h

    # f_score = (g + 1) + h = (s2 + 1) + s6
    addi t0, s2, 1
    add t0, t0, s6     # f_score

    ble t0, s0, .L_ida_h_ok

    # f_score > threshold
    bge t0, s1, .L_prune_h
    mv s1, t0          # next_threshold = f_score
.L_prune_h:
    addi s4, s4, 1
    sb s4, 17(s3)
    j .L_ida_inner_loop

.L_ida_h_ok:
    # Record move: solution_moves[g] = m
    la t0, solution_moves
    add t0, t0, s2
    sb s4, 0(t0)

    # Check cache: canonicalize(next_state)
    la a0, next_state
    la a1, canon_state
    jal ra, canonicalize
    # a0 = canon_id, a1 = k
    mv s7, a1          # s7 = k

    jal ra, lookup_cache
    # a0 = found, a1 = d_rem, a2 = m_canon
    beqz a0, .L_ida_cache_miss

    mv s7, a1          # s7 = d_rem
    addi t0, s2, 1
    add t0, t0, s7     # exact_f
    bne t0, s0, .L_cache_not_exact

    # Early termination! Solved!
    la t0, sol_len
    sw s0, 0(t0)       # sol_len = threshold

    la a0, next_state
    addi a1, s2, 1     # start_pos = g + 1
    mv a2, s7          # d_rem
    jal ra, unpack_cache

    li a0, 1           # success
    j .L_ida_ret

.L_cache_not_exact:
    bge t0, s1, .L_cache_prune
    mv s1, t0          # next_threshold = exact_f
.L_cache_prune:
    addi s4, s4, 1
    sb s4, 17(s3)
    j .L_ida_inner_loop

.L_ida_cache_miss:
    # Cache miss: distance is at least 7!
    # min_f = (g + 1) + 7 = s2 + 8
    addi t0, s2, 8
    ble t0, s0, .L_push_stack

    # min_f > threshold -> prune
    bge t0, s1, .L_miss_prune
    mv s1, t0          # next_threshold = min_f
.L_miss_prune:
    addi s4, s4, 1
    sb s4, 17(s3)
    j .L_ida_inner_loop

.L_push_stack:
    # Push to stack: top++
    addi s2, s2, 1
    slli t0, s2, 4
    slli t1, s2, 2
    add t0, t0, t1
    la t1, search_stack
    add t0, t1, t0     # new frame_ptr

    # Copy next_state to new frame
    la t1, next_state
    lw t2, 0(t1)
    sw t2, 0(t0)
    lw t2, 4(t1)
    sw t2, 4(t0)
    lw t2, 8(t1)
    sw t2, 8(t0)
    lw t2, 12(t1)
    sw t2, 12(t0)

    sb s5, 16(t0)      # last_face = f
    sb x0, 17(t0)      # move_idx = 0
    j .L_ida_inner_loop

.L_ida_next_threshold:
    mv s0, s1          # threshold = next_threshold
    j .L_ida_outer_loop

.L_ida_fail:
    li a0, 0

.L_ida_ret:
    lw s7, 28(sp)
    lw s6, 32(sp)
    lw s5, 36(sp)
    lw s4, 40(sp)
    lw s3, 44(sp)
    lw s2, 48(sp)
    lw s1, 52(sp)
    lw s0, 56(sp)
    lw ra, 60(sp)
    addi sp, sp, 64
    ret
