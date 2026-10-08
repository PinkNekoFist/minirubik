#ifndef CUBE_CORE_H
#define CUBE_CORE_H

#include <stdint.h>
#include <stdbool.h>

enum {
    C = 7,
    O_STATES = 729,
    P_STATES = 5040,
    TOTAL_STATES = P_STATES * O_STATES, // 3,674,160
    MAX_CACHE_DEPTH = 6
};

typedef struct {
    uint8_t p[C];
    uint8_t o[C];
} state_t;

/* Transition tables for 90 degree turns */
static const uint8_t map_p[3][7] = {
    {1, 4, 2, 0, 3, 5, 6},  // R (0)
    {0, 1, 2, 4, 5, 6, 3},  // B (1)
    {0, 2, 5, 3, 1, 4, 6}   // D (2)
};

static const uint8_t map_o[3][7] = {
    {1, 2, 0, 2, 1, 0, 0},  // R (0)
    {0, 0, 0, 1, 2, 1, 2},  // B (1)
    {0, 0, 0, 0, 0, 0, 0}   // D (2)
};

static inline state_t apply_turn_90(state_t s, int f) {
    state_t t;
    for (int i = 0; i < C; ++i) {
        int j = map_p[f][i];
        t.p[i] = s.p[j];
        uint8_t sum = s.o[j] + map_o[f][i];
        t.o[i] = (sum >= 3) ? (sum - 3) : sum;
    }
    return t;
}

static inline state_t apply_move(state_t s, int m) {
    int f = (m < 3) ? 0 : ((m < 6) ? 1 : 2);
    int count = (m % 3) + 1;
    for (int i = 0; i < count; i++) {
        s = apply_turn_90(s, f);
    }
    return s;
}

static inline int get_p_rank(const uint8_t *p) {
    int rank = 0;
    for (int i = 0; i < C; ++i) {
        int n = 0;
        for (int j = i + 1; j < C; ++j) {
            if (p[j] < p[i]) n++;
        }
        rank = rank * (C - i) + n;
    }
    return rank;
}

static inline int get_o_rank(const uint8_t *o) {
    int rank = 0;
    for (int i = 0; i < 6; ++i) {
        rank = rank * 3 + o[i];
    }
    return rank;
}

static inline uint32_t rank_state(state_t s) {
    return (uint32_t)get_p_rank(s.p) * O_STATES + get_o_rank(s.o);
}

/* D3 Symmetry transformations */
static inline state_t transform_k1(state_t s) {
    static const uint8_t slot_from[7] = {2, 5, 6, 1, 4, 3, 0};
    static const uint8_t piece_map[7] = {6, 3, 0, 5, 4, 1, 2};
    state_t res;
    for (int j = 0; j < 7; j++) {
        int from = slot_from[j];
        int old_p = s.p[from];
        int old_o = s.o[from];
        res.p[j] = piece_map[old_p];
        int offset = (j & 1) ? ((old_p & 1) ? 0 : 2) : ((old_p & 1) ? 1 : 0);
        int no = old_o + offset;
        res.o[j] = (no >= 3) ? (no - 3) : no;
    }
    return res;
}

static inline state_t transform_mirror(state_t s) {
    static const uint8_t slot_from[7] = {2, 1, 0, 5, 4, 3, 6};
    static const uint8_t piece_map[7] = {2, 1, 0, 5, 4, 3, 6};
    state_t res;
    for (int j = 0; j < 7; j++) {
        int from = slot_from[j];
        int old_p = s.p[from];
        int old_o = s.o[from];
        res.p[j] = piece_map[old_p];
        int offset = (j & 1) ? ((old_p & 1) ? 0 : 2) : ((old_p & 1) ? 1 : 0);
        int no = (3 - old_o + offset) % 3;
        res.o[j] = no;
    }
    return res;
}

static inline uint32_t canonicalize_state(state_t s, int *best_k, state_t *out_canon) {
    state_t tr[6];
    tr[0] = s;
    tr[1] = transform_k1(tr[0]);
    tr[2] = transform_k1(tr[1]);
    tr[3] = transform_mirror(tr[0]);
    tr[4] = transform_k1(tr[3]);
    tr[5] = transform_k1(tr[4]);

    uint32_t min_r = rank_state(tr[0]);
    int k = 0;
    for (int i = 1; i < 6; i++) {
        uint32_t r = rank_state(tr[i]);
        if (r < min_r) {
            min_r = r;
            k = i;
        }
    }
    if (best_k) *best_k = k;
    if (out_canon) *out_canon = tr[k];
    return min_r;
}

static inline uint32_t canonicalize(state_t s, int *best_k) {
    return canonicalize_state(s, best_k, NULL);
}

/* Symmetry move de-mapping: inverse_move_map[k][m_canon] -> m_real */
static const uint8_t inverse_move_map[6][9] = {
    {0, 1, 2, 3, 4, 5, 6, 7, 8}, // k=0: identity
    {6, 7, 8, 0, 1, 2, 3, 4, 5}, // k=1: rot120
    {3, 4, 5, 6, 7, 8, 0, 1, 2}, // k=2: rot240
    {8, 7, 6, 5, 4, 3, 2, 1, 0}, // k=3: mirror
    {2, 1, 0, 8, 7, 6, 5, 4, 3}, // k=4: mirror + rot120
    {5, 4, 3, 2, 1, 0, 8, 7, 6}  // k=5: mirror + rot240
};

static inline int demap_move(int m_canon, int k) {
    return inverse_move_map[k][m_canon];
}

#endif /* CUBE_CORE_H */
