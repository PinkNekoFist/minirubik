#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <stdbool.h>

#include "cube_core.h"

/* Build Dual PDB */
static uint8_t o_pdb[O_STATES];
static uint8_t p_pdb[P_STATES];

static void build_o_pdb(void)
{
    memset(o_pdb, 0xFF, sizeof(o_pdb));
    state_t *queue = malloc(sizeof(state_t) * O_STATES);
    int head = 0, tail = 0;

    state_t init = {{0}, {0}};
    o_pdb[0] = 0;
    queue[tail++] = init;

    while (head < tail) {
        state_t cur = queue[head++];
        for (int f = 0; f < 3; ++f) {
            state_t next = cur;
            for (int n = 0; n < 3; ++n) {
                next = apply_turn_90(next, f);
                int r = get_o_rank(next.o);
                if (o_pdb[r] == 0xFF) {
                    o_pdb[r] = o_pdb[get_o_rank(cur.o)] + 1;
                    queue[tail++] = next;
                }
            }
        }
    }
    free(queue);
    printf("o_pdb built: %d states visited.\n", tail);
}

static void build_p_pdb(void)
{
    memset(p_pdb, 0xFF, sizeof(p_pdb));
    state_t *queue = malloc(sizeof(state_t) * P_STATES);
    int head = 0, tail = 0;

    state_t init = {{0, 1, 2, 3, 4, 5, 6}, {0}};
    p_pdb[0] = 0;
    queue[tail++] = init;

    while (head < tail) {
        state_t cur = queue[head++];
        for (int f = 0; f < 3; ++f) {
            state_t next = cur;
            for (int n = 0; n < 3; ++n) {
                next = apply_turn_90(next, f);
                int r = get_p_rank(next.p);
                if (p_pdb[r] == 0xFF) {
                    p_pdb[r] = p_pdb[get_p_rank(cur.p)] + 1;
                    queue[tail++] = next;
                }
            }
        }
    }
    free(queue);
    printf("p_pdb built: %d states visited.\n", tail);
}

/* Build 6-step BFS table */
static uint8_t *bfs_depth;
static state_t *bfs_queue;
static uint32_t *bfs_ranks;

typedef struct {
    uint32_t canon_id;
    uint8_t depth;
    uint8_t next_move;
} CacheEntry;

static CacheEntry cache_entries[30000];
static int n_cache_entries = 0;

static int cmp_cache(const void *a, const void *b)
{
    uint32_t id_a = ((const CacheEntry *) a)->canon_id;
    uint32_t id_b = ((const CacheEntry *) b)->canon_id;
    if (id_a < id_b)
        return -1;
    if (id_a > id_b)
        return 1;
    return 0;
}

static void build_cache(void)
{
    bfs_depth = calloc(TOTAL_STATES, 1);
    bfs_queue = malloc(sizeof(state_t) * 70000);
    bfs_ranks = malloc(sizeof(uint32_t) * 70000);

    state_t solved = {{0, 1, 2, 3, 4, 5, 6}, {0}};
    uint32_t solved_rank = rank_state(solved);
    bfs_depth[solved_rank] = 1;
    bfs_queue[0] = solved;
    bfs_ranks[0] = solved_rank;

    int head = 0, tail = 1;
    for (int d = 1; d <= MAX_CACHE_DEPTH; d++) {
        int end = tail;
        for (int i = head; i < end; i++) {
            state_t cur = bfs_queue[i];
            for (int m = 0; m < 9; m++) {
                state_t nxt = apply_move(cur, m);
                uint32_t r = rank_state(nxt);
                if (bfs_depth[r] == 0) {
                    bfs_depth[r] = d + 1;
                    bfs_queue[tail] = nxt;
                    bfs_ranks[tail] = r;
                    tail++;
                }
            }
        }
        head = end;
        printf("BFS Depth %d: total reachable states = %d\n", d, tail);
    }

    // Now find canonical representatives
    // Marker to avoid duplicate canonical entries
    uint8_t *seen_canon = calloc(TOTAL_STATES, 1);

    for (int i = 1; i < tail; i++) {
        state_t canon_s;
        uint32_t min_r = canonicalize_state(bfs_queue[i], NULL, &canon_s);

        if (!seen_canon[min_r]) {
            seen_canon[min_r] = 1;

            int d = bfs_depth[min_r] - 1;
            // Find best next_move for canon_s that decreases depth to d - 1
            int best_move = -1;
            for (int m = 0; m < 9; m++) {
                state_t step = apply_move(canon_s, m);
                uint32_t step_r = rank_state(step);
                if (bfs_depth[step_r] == d) {
                    best_move = m;
                    break;
                }
            }
            if (best_move == -1) {
                fprintf(
                    stderr,
                    "Error: no reducing move found for canonical state %u\n",
                    min_r);
                exit(1);
            }

            cache_entries[n_cache_entries].canon_id = min_r;
            cache_entries[n_cache_entries].depth = (uint8_t) d;
            cache_entries[n_cache_entries].next_move = (uint8_t) best_move;
            n_cache_entries++;
        }
    }

    free(seen_canon);
    printf("Extracted %d unique canonical representatives.\n", n_cache_entries);

    // Sort by canon_id
    qsort(cache_entries, n_cache_entries, sizeof(CacheEntry), cmp_cache);
}

int main(void)
{
    build_o_pdb();
    build_p_pdb();
    build_cache();

    // Write pdb_data.s
    FILE *fp_pdb = fopen("pdb_data.s", "w");
    if (!fp_pdb) {
        perror("fopen pdb_data.s");
        return 1;
    }
    fprintf(fp_pdb, "# Pattern Databases for 2x2x2 Rubik's Cube Solver\n");
    fprintf(fp_pdb, ".data\n");
    fprintf(fp_pdb, ".globl o_pdb\n.globl p_pdb\n\n");

    fprintf(fp_pdb, "o_pdb: # 729 bytes\n");
    for (int i = 0; i < O_STATES; i++) {
        if (i % 16 == 0)
            fprintf(fp_pdb, "\n    .byte ");
        else
            fprintf(fp_pdb, ", ");
        fprintf(fp_pdb, "%d", o_pdb[i]);
    }
    fprintf(fp_pdb, "\n\n");

    fprintf(fp_pdb, "p_pdb: # 5040 bytes\n");
    for (int i = 0; i < P_STATES; i++) {
        if (i % 16 == 0)
            fprintf(fp_pdb, "\n    .byte ");
        else
            fprintf(fp_pdb, ", ");
        fprintf(fp_pdb, "%d", p_pdb[i]);
    }
    fprintf(fp_pdb, "\n");
    fclose(fp_pdb);
    printf("Successfully wrote pdb_data.s (5,769 bytes).\n");

    // Write short_cache.s
    // Packing format: (canon_id << 7) | ((depth & 7) << 4) | (next_move & 0xF)
    FILE *fp_cache = fopen("short_cache.s", "w");
    if (!fp_cache) {
        perror("fopen short_cache.s");
        return 1;
    }
    fprintf(fp_cache,
            "# 6-step D3 Symmetry Cache Table for 2x2x2 Rubik's Cube Solver\n");
    fprintf(fp_cache, "# %d canonical entries (%ld bytes)\n", n_cache_entries,
            n_cache_entries * sizeof(uint32_t));
    fprintf(fp_cache, ".data\n");
    fprintf(fp_cache, ".globl short_cache\n");
    fprintf(fp_cache, ".globl short_cache_size\n\n");

    fprintf(fp_cache, "short_cache_size:\n");
    fprintf(fp_cache, "    .4byte %d\n\n", n_cache_entries);

    fprintf(fp_cache, "short_cache:\n");
    for (int i = 0; i < n_cache_entries; i++) {
        uint32_t id = cache_entries[i].canon_id;
        uint32_t d = cache_entries[i].depth;
        uint32_t m = cache_entries[i].next_move;
        uint32_t packed = (id << 7) | ((d & 7) << 4) | (m & 0xF);

        if (i % 8 == 0)
            fprintf(fp_cache, "\n    .4byte ");
        else
            fprintf(fp_cache, ", ");
        fprintf(fp_cache, "0x%08X", packed);
    }
    fprintf(fp_cache, "\n");
    fclose(fp_cache);
    printf("Successfully wrote short_cache.s (%d entries, %.2f KiB).\n",
           n_cache_entries, (n_cache_entries * 4.0) / 1024.0);

    // Assemble unified solver.s for Ripes if solver_core.s exists
    if (system("test -f solver_core.s") == 0) {
        if (system("cat solver_core.s pdb_data.s short_cache.s > solver.s") ==
            0) {
            printf("Successfully generated unified solver.s for Ripes!\n");
        }
    }

    return 0;
}
