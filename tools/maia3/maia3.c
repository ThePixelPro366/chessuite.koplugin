/*
 * Maia3 (5M) as a tiny UCI engine, for e-readers.
 *
 * Maia3 is the human-move model of the University of Toronto CSSLab
 * (https://github.com/CSSLab/maia3, AGPL-3.0; weights from
 * https://huggingface.co/UofTCSSLab/Maia3-5M). It predicts the move a
 * player of a given rating would make; it does not search. This file is a
 * plain C port of its inference (maia3/models.py) so it runs without
 * Python or PyTorch: about 0.3 GFLOP per position.
 *
 * The weights are read from maia3-5m.bin next to the binary (made by
 * tools/export-maia3.py) or from the path given as the first argument.
 *
 * UCI subset:
 *   setoption name Elo|SelfElo|OppoElo|MultiPV value N
 *   position startpos|fen <fen> [moves ...]
 *   go [searchmoves m1 m2 ...]   (pass the legal moves: there is no move
 *                                 generator here)
 * Each candidate comes back as
 *   info depth 1 multipv k score cp <eval> nodes 1 prob <p> pv <move>
 * sorted by the probability that a human of that rating plays it. The
 * score is the model's own guess of the game result, the same for all lines.
 *
 * Like the official UCI wrapper's default, the current position fills all
 * eight history slots.
 */
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define SQ 64
#define MAXMOVES 256

static int DIM, HEADS, BLOCKS, MLP, EMB, GEN, GAB_HID, HEAD_HID, TOK, IN;

typedef struct {
    float *in_proj, *out_proj, *sm2_w, *sm2_b, *ln1_w, *ln1_b, *sm3_w, *sm3_b, *ln2_w, *ln2_b;
    float *lin1_w, *lin1_b, *lin2_w, *lin2_b, *norm1, *norm2;
} Layer;

static float *elo_low, *elo_high, *tok_w, *tok_b, *gab_w;
static Layer *layers;
static float *fnorm_w, *fnorm_b, *from_w, *to_w, *promo_w, *last_w, *last_b, *vh_w, *vh_b, *v_w, *v_b;

/* ---------------------------------------------------------------- weights */

static float half_to_float(uint16_t h) {
    uint32_t sign = (uint32_t)(h & 0x8000) << 16, exp = (h >> 10) & 0x1f, man = h & 0x3ff, bits;
    if (exp == 0) {
        if (man == 0) bits = sign;
        else {
            exp = 127 - 15 + 1;
            while (!(man & 0x400)) { man <<= 1; exp--; }
            bits = sign | (exp << 23) | ((man & 0x3ff) << 13);
        }
    } else if (exp == 31) bits = sign | 0x7f800000 | (man << 13);
    else bits = sign | ((exp + 127 - 15) << 23) | (man << 13);
    float f;
    memcpy(&f, &bits, 4);
    return f;
}

static FILE *wf;
static int load_failed;

static float *take(size_t n) {
    float *out = malloc(n * sizeof(float));
    uint16_t *tmp = malloc(n * 2);
    if (!out || !tmp || fread(tmp, 2, n, wf) != n) { load_failed = 1; free(tmp); return out; }
    for (size_t i = 0; i < n; i++) {
        unsigned char *b = (unsigned char *)&tmp[i];
        tmp[i] = (uint16_t)(b[0] | (b[1] << 8));
        out[i] = half_to_float(tmp[i]);
    }
    free(tmp);
    return out;
}

static int load_weights(const char *path) {
    wf = fopen(path, "rb");
    if (!wf) return 0;
    char magic[8];
    int32_t cfg[9];
    if (fread(magic, 1, 8, wf) != 8 || memcmp(magic, "MAIA3W01", 8) || fread(cfg, 4, 9, wf) != 9) {
        fclose(wf);
        return 0;
    }
    DIM = cfg[0]; HEADS = cfg[1]; BLOCKS = cfg[2]; MLP = cfg[3]; EMB = cfg[4];
    GEN = cfg[5]; GAB_HID = cfg[6]; HEAD_HID = cfg[7]; TOK = cfg[8];
    IN = TOK + 2 * EMB;
    elo_low = take(EMB); elo_high = take(EMB);
    tok_w = take((size_t)DIM * IN); tok_b = take(DIM);
    gab_w = take((size_t)SQ * SQ * GEN);
    layers = calloc(BLOCKS, sizeof(Layer));
    for (int i = 0; i < BLOCKS; i++) {
        Layer *l = &layers[i];
        l->in_proj = take((size_t)3 * DIM * DIM);
        l->out_proj = take((size_t)DIM * DIM);
        l->sm2_w = take((size_t)GAB_HID * DIM); l->sm2_b = take(GAB_HID);
        l->ln1_w = take(GAB_HID); l->ln1_b = take(GAB_HID);
        l->sm3_w = take((size_t)HEADS * GEN * GAB_HID); l->sm3_b = take(HEADS * GEN);
        l->ln2_w = take(HEADS * GEN); l->ln2_b = take(HEADS * GEN);
        l->lin1_w = take((size_t)MLP * DIM); l->lin1_b = take(MLP);
        l->lin2_w = take((size_t)DIM * MLP); l->lin2_b = take(DIM);
        l->norm1 = take(DIM); l->norm2 = take(DIM);
    }
    fnorm_w = take(DIM); fnorm_b = take(DIM);
    from_w = take((size_t)HEAD_HID * DIM); to_w = take((size_t)HEAD_HID * DIM);
    promo_w = take(4 * HEAD_HID);
    last_w = take(DIM); last_b = take(DIM);
    vh_w = take((size_t)HEAD_HID * DIM); vh_b = take(HEAD_HID);
    v_w = take(3 * HEAD_HID); v_b = take(3);
    fclose(wf);
    return !load_failed;
}

/* ------------------------------------------------------------------- math */

/* y[t][o] = W[o] . x[t] (+ b[o]) for rows t < n; W is out x in */
static void linear(const float *x, int n, int in, const float *w, const float *b, int out, float *y) {
    int t = 0;
    for (; t + 4 <= n; t += 4) {
        const float *x0 = x + (size_t)t * in, *x1 = x0 + in, *x2 = x1 + in, *x3 = x2 + in;
        for (int o = 0; o < out; o++) {
            const float *wr = w + (size_t)o * in;
            float s0 = 0, s1 = 0, s2 = 0, s3 = 0;
            for (int i = 0; i < in; i++) {
                float wv = wr[i];
                s0 += wv * x0[i]; s1 += wv * x1[i]; s2 += wv * x2[i]; s3 += wv * x3[i];
            }
            float bb = b ? b[o] : 0;
            y[(size_t)t * out + o] = s0 + bb;
            y[(size_t)(t + 1) * out + o] = s1 + bb;
            y[(size_t)(t + 2) * out + o] = s2 + bb;
            y[(size_t)(t + 3) * out + o] = s3 + bb;
        }
    }
    for (; t < n; t++) {
        const float *xr = x + (size_t)t * in;
        for (int o = 0; o < out; o++) {
            const float *wr = w + (size_t)o * in;
            float s = 0;
            for (int i = 0; i < in; i++) s += wr[i] * xr[i];
            y[(size_t)t * out + o] = s + (b ? b[o] : 0);
        }
    }
}

static float gelu(float v) { return 0.5f * v * (1.0f + erff(v * 0.70710678f)); }

static void layer_norm(float *x, int n, const float *w, const float *b) {
    float mean = 0, var = 0;
    for (int i = 0; i < n; i++) mean += x[i];
    mean /= n;
    for (int i = 0; i < n; i++) var += (x[i] - mean) * (x[i] - mean);
    float inv = 1.0f / sqrtf(var / n + 1e-5f);
    for (int i = 0; i < n; i++) x[i] = (x[i] - mean) * inv * w[i] + b[i];
}

static void rms_norm(float *x, int n, const float *w) {
    float ss = 0;
    for (int i = 0; i < n; i++) ss += x[i] * x[i];
    float inv = 1.0f / sqrtf(ss / n + 1.1920929e-07f);
    for (int i = 0; i < n; i++) x[i] = x[i] * inv * w[i];
}

/* ------------------------------------------------------------------ board */

/* board[sq], sq = rank * 8 + file (a1 = 0): 0 empty, 1..6 white PNBRQK, 7..12 black */
static int board[SQ], white_to_move = 1, castle_k[2], castle_q[2], ep_sq = -1;

static int piece_code(char c) {
    const char *s = "PNBRQKpnbrqk";
    const char *p = strchr(s, c);
    return p && c ? (int)(p - s) + 1 : 0;
}

static void set_fen(const char *fen) {
    memset(board, 0, sizeof board);
    int rank = 7, file = 0;
    const char *p = fen;
    for (; *p && *p != ' '; p++) {
        if (*p == '/') { rank--; file = 0; }
        else if (*p >= '1' && *p <= '8') file += *p - '0';
        else if (rank >= 0 && file < 8) board[rank * 8 + file++] = piece_code(*p);
    }
    while (*p == ' ') p++;
    white_to_move = *p != 'b';
    while (*p && *p != ' ') p++;
    while (*p == ' ') p++;
    castle_k[0] = castle_q[0] = castle_k[1] = castle_q[1] = 0;
    for (; *p && *p != ' '; p++) {
        if (*p == 'K') castle_k[0] = 1;
        if (*p == 'Q') castle_q[0] = 1;
        if (*p == 'k') castle_k[1] = 1;
        if (*p == 'q') castle_q[1] = 1;
    }
    while (*p == ' ') p++;
    ep_sq = (p[0] >= 'a' && p[0] <= 'h' && p[1] >= '1' && p[1] <= '8') ? (p[1] - '1') * 8 + (p[0] - 'a') : -1;
}

static int parse_sq(const char *s) {
    if (s[0] < 'a' || s[0] > 'h' || s[1] < '1' || s[1] > '8') return -1;
    return (s[1] - '1') * 8 + (s[0] - 'a');
}

/* Plays a UCI move without checking it. */
static void apply_move(const char *m) {
    int from = parse_sq(m), to = from >= 0 ? parse_sq(m + 2) : -1;
    if (from < 0 || to < 0) return;
    int pc = board[from], type = pc > 6 ? pc - 6 : pc, black = pc > 6;
    int new_ep = -1;
    if (type == 1) {
        if (to == ep_sq && (to & 7) != (from & 7) && !board[to]) board[to + (black ? 8 : -8)] = 0;
        if (abs(to - from) == 16) new_ep = (from + to) / 2;
        if (m[4]) {
            int promo = piece_code(m[4] - 'a' + 'A');
            if (promo) pc = promo + (black ? 6 : 0);
        }
    }
    if (type == 6 && abs(to - from) == 2) {
        int rf = to > from ? from + 3 : from - 4, rt = to > from ? from + 1 : from - 1;
        board[rt] = board[rf];
        board[rf] = 0;
    }
    board[to] = pc;
    board[from] = 0;
    ep_sq = new_ep;
    white_to_move = !white_to_move;
}

/* ---------------------------------------------------------------- network */

static int self_elo = 1500, oppo_elo = 1500, multipv = 1;

static float *X, *Y, *QKV, *ATT, *HID, *FROM, *TO;

static void elo_embedding(int elo, float *out) {
    if (elo < 0) elo = 0;
    if (elo > 5000) elo = 5000;
    float wl = elo / 5000.0f, wh = 1 - wl;
    for (int i = 0; i < EMB; i++) out[i] = wl * elo_low[i] + wh * elo_high[i];
}

/* Runs the network on the current position, seen from the side to move.
   Fills FROM and TO (the policy head inputs) and returns the WDL logits. */
static void forward(float wdl[3]) {
    float *in = calloc((size_t)SQ * IN, sizeof(float));
    float *se = malloc(EMB * sizeof(float)), *oe = malloc(EMB * sizeof(float));
    elo_embedding(self_elo, se);
    elo_embedding(oppo_elo, oe);
    for (int sq = 0; sq < SQ; sq++) {
        int pc = white_to_move ? board[sq] : board[sq ^ 56];
        if (!white_to_move && pc) pc = pc > 6 ? pc - 6 : pc + 6;
        float *row = in + (size_t)sq * IN;
        if (pc)
            for (int h = 0; h < TOK / 12; h++) row[h * 12 + pc - 1] = 1;
        memcpy(row + TOK, se, EMB * sizeof(float));
        memcpy(row + TOK + EMB, oe, EMB * sizeof(float));
    }
    linear(in, SQ, IN, tok_w, tok_b, DIM, X);
    free(in); free(se); free(oe);

    int hd = DIM / HEADS;
    float scale = 1.0f / sqrtf((float)hd);
    float *mean = malloc(DIM * sizeof(float)), *g1 = malloc(GAB_HID * sizeof(float));
    float *g2 = malloc(HEADS * GEN * sizeof(float)), *bias = malloc((size_t)SQ * SQ * sizeof(float));
    float *sc = malloc(SQ * sizeof(float));
    for (int li = 0; li < BLOCKS; li++) {
        Layer *l = &layers[li];
        /* geometric attention bias from the mean of the square tokens */
        for (int i = 0; i < DIM; i++) mean[i] = 0;
        for (int t = 0; t < SQ; t++) for (int i = 0; i < DIM; i++) mean[i] += X[t * DIM + i];
        for (int i = 0; i < DIM; i++) mean[i] /= SQ;
        linear(mean, 1, DIM, l->sm2_w, l->sm2_b, GAB_HID, g1);
        for (int i = 0; i < GAB_HID; i++) g1[i] = gelu(g1[i]);
        layer_norm(g1, GAB_HID, l->ln1_w, l->ln1_b);
        linear(g1, 1, GAB_HID, l->sm3_w, l->sm3_b, HEADS * GEN, g2);
        for (int i = 0; i < HEADS * GEN; i++) g2[i] = gelu(g2[i]);
        layer_norm(g2, HEADS * GEN, l->ln2_w, l->ln2_b);

        linear(X, SQ, DIM, l->in_proj, NULL, 3 * DIM, QKV);
        for (int h = 0; h < HEADS; h++) {
            /* bias[i][j] for this head */
            linear(g2 + h * GEN, 1, GEN, gab_w, NULL, SQ * SQ, bias);
            for (int i = 0; i < SQ; i++) {
                const float *q = QKV + (size_t)i * 3 * DIM + h * hd;
                float mx = -1e30f;
                for (int j = 0; j < SQ; j++) {
                    const float *k = QKV + (size_t)j * 3 * DIM + DIM + h * hd;
                    float s = 0;
                    for (int d = 0; d < hd; d++) s += q[d] * k[d];
                    s = s * scale + bias[i * SQ + j];
                    sc[j] = s;
                    if (s > mx) mx = s;
                }
                float sum = 0;
                for (int j = 0; j < SQ; j++) { sc[j] = expf(sc[j] - mx); sum += sc[j]; }
                float *o = ATT + (size_t)i * DIM + h * hd;
                for (int d = 0; d < hd; d++) o[d] = 0;
                for (int j = 0; j < SQ; j++) {
                    const float *v = QKV + (size_t)j * 3 * DIM + 2 * DIM + h * hd;
                    float p = sc[j] / sum;
                    for (int d = 0; d < hd; d++) o[d] += p * v[d];
                }
            }
        }
        linear(ATT, SQ, DIM, l->out_proj, NULL, DIM, Y);
        for (int t = 0; t < SQ; t++) {
            for (int i = 0; i < DIM; i++) X[t * DIM + i] += Y[t * DIM + i];
            rms_norm(X + t * DIM, DIM, l->norm1);
        }
        linear(X, SQ, DIM, l->lin1_w, l->lin1_b, MLP, HID);
        for (int i = 0; i < SQ * MLP; i++) HID[i] = gelu(HID[i]);
        linear(HID, SQ, MLP, l->lin2_w, l->lin2_b, DIM, Y);
        for (int t = 0; t < SQ; t++) {
            for (int i = 0; i < DIM; i++) X[t * DIM + i] += Y[t * DIM + i];
            rms_norm(X + t * DIM, DIM, l->norm2);
        }
    }
    for (int t = 0; t < SQ; t++) layer_norm(X + t * DIM, DIM, fnorm_w, fnorm_b);

    linear(X, SQ, DIM, from_w, NULL, HEAD_HID, FROM);
    linear(X, SQ, DIM, to_w, NULL, HEAD_HID, TO);

    /* value head */
    float *vh = malloc(HEAD_HID * sizeof(float));
    for (int i = 0; i < DIM; i++) mean[i] = 0;
    for (int t = 0; t < SQ; t++) for (int i = 0; i < DIM; i++) mean[i] += X[t * DIM + i];
    for (int i = 0; i < DIM; i++) mean[i] /= SQ;
    layer_norm(mean, DIM, last_w, last_b);
    linear(mean, 1, DIM, vh_w, vh_b, HEAD_HID, vh);
    for (int i = 0; i < HEAD_HID; i++) if (vh[i] < 0) vh[i] = 0;
    linear(vh, 1, HEAD_HID, v_w, v_b, 3, wdl);
    free(vh); free(mean); free(g1); free(g2); free(bias); free(sc);
}

/* The policy logit of a move given in real (unmirrored) squares. */
static float move_logit(int from, int to, char promo) {
    if (!white_to_move) { from ^= 56; to ^= 56; }
    float s = 0;
    for (int d = 0; d < HEAD_HID; d++) s += FROM[from * HEAD_HID + d] * TO[to * HEAD_HID + d];
    s /= sqrtf((float)HEAD_HID);
    if (promo) {
        const char *order = "qrbn";
        const char *p = strchr(order, promo);
        int k = p ? (int)(p - order) : 0;
        float b = 0;
        for (int d = 0; d < HEAD_HID; d++) b += promo_w[k * HEAD_HID + d] * TO[to * HEAD_HID + d];
        s += b * sqrtf((float)HEAD_HID);
    }
    return s;
}

/* ------------------------------------------------------------------- UCI */

typedef struct { char uci[8]; float logit, prob; } Cand;

static int cmp_cand(const void *a, const void *b) {
    float d = ((const Cand *)b)->prob - ((const Cand *)a)->prob;
    return d > 0 ? 1 : d < 0 ? -1 : 0;
}

static void go(char *args) {
    static Cand c[MAXMOVES];
    int n = 0;
    char *sm = strstr(args, "searchmoves");
    if (sm) {
        char *tok = strtok(sm + 11, " \t\n");
        while (tok && n < MAXMOVES) {
            if (parse_sq(tok) >= 0 && parse_sq(tok + 2) >= 0 && strlen(tok) <= 5) {
                strcpy(c[n].uci, tok);
                n++;
            }
            tok = strtok(NULL, " \t\n");
        }
    } else {
        /* no legal move list: every from-to pair starting on one of our pieces */
        for (int f = 0; f < SQ && n < MAXMOVES; f++) {
            int pc = board[f];
            if (!pc || (pc > 6) == white_to_move) continue;
            for (int t = 0; t < SQ && n < MAXMOVES; t++) {
                int q = board[t];
                if (t == f || (q && (q > 6) != white_to_move)) continue;
                sprintf(c[n++].uci, "%c%c%c%c", 'a' + (f & 7), '1' + (f >> 3), 'a' + (t & 7), '1' + (t >> 3));
            }
        }
    }
    if (n == 0) { printf("bestmove (none)\n"); fflush(stdout); return; }
    float wdl[3];
    forward(wdl);
    float mx = -1e30f, sum = 0;
    for (int i = 0; i < n; i++) {
        c[i].logit = move_logit(parse_sq(c[i].uci), parse_sq(c[i].uci + 2), c[i].uci[4]);
        if (c[i].logit > mx) mx = c[i].logit;
    }
    for (int i = 0; i < n; i++) { c[i].prob = expf(c[i].logit - mx); sum += c[i].prob; }
    for (int i = 0; i < n; i++) c[i].prob /= sum;
    qsort(c, n, sizeof(Cand), cmp_cand);
    /* [loss, draw, win] for the side to move, turned into centipawns */
    float vm = fmaxf(wdl[0], fmaxf(wdl[1], wdl[2])), e0 = expf(wdl[0] - vm), e1 = expf(wdl[1] - vm),
          e2 = expf(wdl[2] - vm), es = e0 + e1 + e2;
    float d = (e2 - e0) / es;
    if (d > 0.999f) d = 0.999f;
    if (d < -0.999f) d = -0.999f;
    int cp = (int)lroundf(logf((1 + d) / (1 - d)) / 0.00368208f);
    int lines = multipv < n ? multipv : n;
    for (int i = 0; i < lines; i++)
        printf("info depth 1 multipv %d score cp %d nodes 1 prob %.5f pv %s\n", i + 1, cp, c[i].prob, c[i].uci);
    printf("bestmove %s\n", c[0].uci);
    fflush(stdout);
}

static void setoption(char *line) {
    char *name = strstr(line, "name "), *value = strstr(line, " value ");
    if (!name || !value) return;
    *value = 0;
    name += 5;
    int v = atoi(value + 7);
    if (!strcasecmp(name, "Elo")) self_elo = oppo_elo = v;
    else if (!strcasecmp(name, "SelfElo")) self_elo = v;
    else if (!strcasecmp(name, "OppoElo")) oppo_elo = v;
    else if (!strcasecmp(name, "MultiPV")) multipv = v < 1 ? 1 : v > MAXMOVES ? MAXMOVES : v;
}

static void position(char *line) {
    char *p = line + 8;
    while (*p == ' ') p++;
    char *moves = strstr(p, " moves ");
    if (moves) *moves = 0;
    if (!strncmp(p, "startpos", 8)) set_fen("rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1");
    else if (!strncmp(p, "fen ", 4)) set_fen(p + 4);
    if (moves) {
        char *tok = strtok(moves + 7, " \t\n");
        while (tok) { apply_move(tok); tok = strtok(NULL, " \t\n"); }
    }
}

int main(int argc, char **argv) {
    char path[4096];
    if (argc > 1) snprintf(path, sizeof path, "%s", argv[1]);
    else {
        ssize_t k = readlink("/proc/self/exe", path, sizeof path - 32);
        if (k <= 0) { snprintf(path, sizeof path, "%s", argv[0]); k = (ssize_t)strlen(path); }
        path[k] = 0;
        char *slash = strrchr(path, '/');
        strcpy(slash ? slash + 1 : path, "maia3-5m.bin");
    }
    if (!load_weights(path)) {
        printf("info string cannot read weights %s\n", path);
        fflush(stdout);
        return 1;
    }
    X = malloc((size_t)SQ * DIM * sizeof(float));
    Y = malloc((size_t)SQ * DIM * sizeof(float));
    ATT = malloc((size_t)SQ * DIM * sizeof(float));
    QKV = malloc((size_t)SQ * 3 * DIM * sizeof(float));
    HID = malloc((size_t)SQ * MLP * sizeof(float));
    FROM = malloc((size_t)SQ * HEAD_HID * sizeof(float));
    TO = malloc((size_t)SQ * HEAD_HID * sizeof(float));
    set_fen("rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1");

    char line[16384];
    while (fgets(line, sizeof line, stdin)) {
        line[strcspn(line, "\r\n")] = 0;
        if (!strcmp(line, "uci")) {
            printf("id name Maia3 5M\nid author CSSLab (C port for Chessuite)\n");
            printf("option name Elo type spin default 1500 min 0 max 5000\n");
            printf("option name SelfElo type spin default 1500 min 0 max 5000\n");
            printf("option name OppoElo type spin default 1500 min 0 max 5000\n");
            printf("option name MultiPV type spin default 1 min 1 max %d\n", MAXMOVES);
            printf("uciok\n");
        } else if (!strcmp(line, "isready")) printf("readyok\n");
        else if (!strncmp(line, "setoption", 9)) setoption(line);
        else if (!strncmp(line, "position", 8)) position(line);
        else if (!strncmp(line, "go", 2)) go(line);
        else if (!strcmp(line, "quit")) break;
        fflush(stdout);
    }
    return 0;
}
