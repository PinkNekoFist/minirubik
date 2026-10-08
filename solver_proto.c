#include <stdio.h>
#include <stdint.h>
#include <stdbool.h>
#include <string.h>
#include <stdlib.h>

#include "cube_core.h"

enum { MAX_DEPTH = 14 };

/* External data from assembly (.rodata) */
extern const uint8_t o_pdb[O_STATES];
extern const uint8_t p_pdb[P_STATES];
extern const uint32_t short_cache[];
extern const uint32_t short_cache_size;

typedef struct {
    state_t state;
    uint8_t last_face;  // 0: R, 1: B, 2: D, 3: None
    uint8_t move_idx;   // 0..8
} SearchFrame;

static SearchFrame stack[MAX_DEPTH];
static uint8_t solution_moves[MAX_DEPTH];
static uint64_t nodes_visited = 0;

static inline int get_h(state_t s)
{
    int h_o = o_pdb[get_o_rank(s.o)];
    int h_p = p_pdb[get_p_rank(s.p)];
    return (h_o > h_p) ? h_o : h_p;
}

/* Binary search in cache table */
static bool lookup_cache(uint32_t target_id, int *d_remain, int *next_move)
{
    int low = 0, high = (int) short_cache_size - 1;
    while (low <= high) {
        int mid = (low + high) / 2;
        uint32_t entry = short_cache[mid];
        uint32_t id = entry >> 7;
        if (id == target_id) {
            *d_remain = (entry >> 4) & 7;
            *next_move = entry & 0xF;
            return true;
        }
        if (id < target_id) {
            low = mid + 1;
        } else {
            high = mid - 1;
        }
    }
    return false;
}

/* Unpack remaining moves from cache */
static void unpack_cache(state_t s, int start_pos, int d_remain)
{
    state_t cur = s;
    for (int step = 0; step < d_remain; step++) {
        int k = 0;
        uint32_t canon_id = canonicalize(cur, &k);
        int d_rem = 0, m_canon = 0;
        if (!lookup_cache(canon_id, &d_rem, &m_canon)) {
            fprintf(stderr, "Fatal error: cache miss during unpacking!\n");
            exit(1);
        }
        int m_real = demap_move(m_canon, k);
        solution_moves[start_pos + step] = m_real;
        cur = apply_move(cur, m_real);
    }
}

/* IDA* Solver */
bool solve_mitm(state_t start, int *sol_len)
{
    nodes_visited = 0;

    int h_start = get_h(start);
    if (h_start == 0) {
        *sol_len = 0;
        return true;
    }

    // Level 0 cache check
    int k0 = 0;
    uint32_t canon0 = canonicalize(start, &k0);
    int d0 = 0, m0 = 0;
    if (lookup_cache(canon0, &d0, &m0)) {
        unpack_cache(start, 0, d0);
        *sol_len = d0;
        return true;
    }

    // Start IDA* search
    int threshold = (h_start > 7) ? h_start : 7;
    while (threshold <= 11) {
        int next_threshold = 99;
        int top = 0;

        stack[0].state = start;
        stack[0].last_face = 3;  // 3 for none
        stack[0].move_idx = 0;

        while (top >= 0) {
            int g = top;
            int m = stack[top].move_idx;

            if (m >= 9) {
                top--;
                if (top >= 0)
                    stack[top].move_idx++;
                continue;
            }

            int f = (m < 3) ? 0 : ((m < 6) ? 1 : 2);
            if (f == stack[top].last_face) {
                stack[top].move_idx++;
                continue;
            }

            nodes_visited++;
            state_t next_s = apply_move(stack[top].state, m);
            int h = get_h(next_s);
            int f_score = (g + 1) + h;

            if (f_score > threshold) {
                if (f_score < next_threshold)
                    next_threshold = f_score;
                stack[top].move_idx++;
                continue;
            }

            solution_moves[g] = m;

            // Cache interception
            int k = 0;
            uint32_t canon_id = canonicalize(next_s, &k);
            int d_rem = 0, m_canon = 0;
            if (lookup_cache(canon_id, &d_rem, &m_canon)) {
                int exact_f = (g + 1) + d_rem;
                if (exact_f == threshold) {
                    unpack_cache(next_s, g + 1, d_rem);
                    *sol_len = threshold;
                    return true;
                }
                if (exact_f < next_threshold)
                    next_threshold = exact_f;
                stack[top].move_idx++;
                continue;
            }

            // Cache miss
            int min_f = (g + 1) + 7;
            if (min_f > threshold) {
                if (min_f < next_threshold)
                    next_threshold = min_f;
                stack[top].move_idx++;
                continue;
            }

            // Push to stack (only if g + 1 <= threshold - 7 <= 4)
            top++;
            stack[top].state = next_s;
            stack[top].last_face = f;
            stack[top].move_idx = 0;
        }

        threshold = next_threshold;
    }

    return false;
}

int main(int argc, char **argv)
{
    if (argc != 2 || strlen(argv[1]) != 14) {
        printf("Usage: %s <14-char-state>\n", argv[0]);
        return 2;
    }

    state_t start;
    unsigned seen = 0, sum = 0;
    for (int i = 0; i < C; i++) {
        unsigned p = (unsigned) (argv[1][i] - '1');
        unsigned o = (unsigned) (argv[1][i + C] - '1');
        if (p >= C || o >= 3 || (seen >> p & 1))
            return 2;
        start.p[i] = p;
        start.o[i] = o;
        seen |= 1U << p;
        sum += o;
    }
    if (sum % 3)
        return 2;

    int sol_len = 0;
    if (solve_mitm(start, &sol_len)) {
        static const char *face_names = "RBD";
        static const char *suf[] = {"", "2", "'"};
        const char *sep = "";
        for (int i = 0; i < sol_len; i++) {
            int m = solution_moves[i];
            int f = (m < 3) ? 0 : ((m < 6) ? 1 : 2);
            int n = m % 3;
            printf("%s%c%s", sep, face_names[f], suf[n]);
            sep = " ";
        }
        printf("\n");
        fprintf(stderr, "[Info] Solved in %d moves, nodes visited: %lu\n",
                sol_len, nodes_visited);
        return 0;
    } else {
        return 1;
    }
}
