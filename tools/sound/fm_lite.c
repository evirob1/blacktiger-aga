/* A YM2203 model to plan a real-time one in 68k code by: the two chips' FM
 * (after ymfm, MAME's emulation by Aaron Giles, BSD licence: its tables,
 * envelope and phase logic) and SSG, from a log of register writes, at a
 * lower output rate than the chip's - one operator evaluation per output
 * sample, the phases and envelopes stepped as the chip does. To measure what
 * a lower rate costs against the real thing (tools/sound/compare.py).
 *
 * input: lines "time_seconds chip register value" (hex register / value)
 * usage: fm_lite log.txt seconds rate out.wav
 */
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define CLOCK 3579545.0
#define FM_RATE (CLOCK / 72)            /* the chip's FM sample rate (prescaler 6) */
#define EG_QUIET 0x380

static const uint16_t sin_tab[256] = {
    0x859,0x6c3,0x607,0x58b,0x52e,0x4e4,0x4a6,0x471,0x443,0x41a,0x3f5,0x3d3,0x3b5,0x398,0x37e,0x365,
    0x34e,0x339,0x324,0x311,0x2ff,0x2ed,0x2dc,0x2cd,0x2bd,0x2af,0x2a0,0x293,0x286,0x279,0x26d,0x261,
    0x256,0x24b,0x240,0x236,0x22c,0x222,0x218,0x20f,0x206,0x1fd,0x1f5,0x1ec,0x1e4,0x1dc,0x1d4,0x1cd,
    0x1c5,0x1be,0x1b7,0x1b0,0x1a9,0x1a2,0x19b,0x195,0x18f,0x188,0x182,0x17c,0x177,0x171,0x16b,0x166,
    0x160,0x15b,0x155,0x150,0x14b,0x146,0x141,0x13c,0x137,0x133,0x12e,0x129,0x125,0x121,0x11c,0x118,
    0x114,0x10f,0x10b,0x107,0x103,0x0ff,0x0fb,0x0f8,0x0f4,0x0f0,0x0ec,0x0e9,0x0e5,0x0e2,0x0de,0x0db,
    0x0d7,0x0d4,0x0d1,0x0cd,0x0ca,0x0c7,0x0c4,0x0c1,0x0be,0x0bb,0x0b8,0x0b5,0x0b2,0x0af,0x0ac,0x0a9,
    0x0a7,0x0a4,0x0a1,0x09f,0x09c,0x099,0x097,0x094,0x092,0x08f,0x08d,0x08a,0x088,0x086,0x083,0x081,
    0x07f,0x07d,0x07a,0x078,0x076,0x074,0x072,0x070,0x06e,0x06c,0x06a,0x068,0x066,0x064,0x062,0x060,
    0x05e,0x05c,0x05b,0x059,0x057,0x055,0x053,0x052,0x050,0x04e,0x04d,0x04b,0x04a,0x048,0x046,0x045,
    0x043,0x042,0x040,0x03f,0x03e,0x03c,0x03b,0x039,0x038,0x037,0x035,0x034,0x033,0x031,0x030,0x02f,
    0x02e,0x02d,0x02b,0x02a,0x029,0x028,0x027,0x026,0x025,0x024,0x023,0x022,0x021,0x020,0x01f,0x01e,
    0x01d,0x01c,0x01b,0x01a,0x019,0x018,0x017,0x017,0x016,0x015,0x014,0x014,0x013,0x012,0x011,0x011,
    0x010,0x00f,0x00f,0x00e,0x00d,0x00d,0x00c,0x00c,0x00b,0x00a,0x00a,0x009,0x009,0x008,0x008,0x007,
    0x007,0x007,0x006,0x006,0x005,0x005,0x005,0x004,0x004,0x004,0x003,0x003,0x003,0x002,0x002,0x002,
    0x002,0x001,0x001,0x001,0x001,0x001,0x001,0x001,0x000,0x000,0x000,0x000,0x000,0x000,0x000,0x000
};
static uint16_t pow_tab[256];           /* ymfm's power table: (mantissa | 0x400) << 2, reversed */
static const uint16_t pow_src[256] = {
    0x3fa,0x3f5,0x3ef,0x3ea,0x3e4,0x3df,0x3da,0x3d4,0x3cf,0x3c9,0x3c4,0x3bf,0x3b9,0x3b4,0x3ae,0x3a9,
    0x3a4,0x39f,0x399,0x394,0x38f,0x38a,0x384,0x37f,0x37a,0x375,0x370,0x36a,0x365,0x360,0x35b,0x356,
    0x351,0x34c,0x347,0x342,0x33d,0x338,0x333,0x32e,0x329,0x324,0x31f,0x31a,0x315,0x310,0x30b,0x306,
    0x302,0x2fd,0x2f8,0x2f3,0x2ee,0x2e9,0x2e5,0x2e0,0x2db,0x2d6,0x2d2,0x2cd,0x2c8,0x2c4,0x2bf,0x2ba,
    0x2b5,0x2b1,0x2ac,0x2a8,0x2a3,0x29e,0x29a,0x295,0x291,0x28c,0x288,0x283,0x27f,0x27a,0x276,0x271,
    0x26d,0x268,0x264,0x25f,0x25b,0x257,0x252,0x24e,0x249,0x245,0x241,0x23c,0x238,0x234,0x230,0x22b,
    0x227,0x223,0x21e,0x21a,0x216,0x212,0x20e,0x209,0x205,0x201,0x1fd,0x1f9,0x1f5,0x1f0,0x1ec,0x1e8,
    0x1e4,0x1e0,0x1dc,0x1d8,0x1d4,0x1d0,0x1cc,0x1c8,0x1c4,0x1c0,0x1bc,0x1b8,0x1b4,0x1b0,0x1ac,0x1a8,
    0x1a4,0x1a0,0x19c,0x199,0x195,0x191,0x18d,0x189,0x185,0x181,0x17e,0x17a,0x176,0x172,0x16f,0x16b,
    0x167,0x163,0x160,0x15c,0x158,0x154,0x151,0x14d,0x149,0x146,0x142,0x13e,0x13b,0x137,0x134,0x130,
    0x12c,0x129,0x125,0x122,0x11e,0x11b,0x117,0x114,0x110,0x10c,0x109,0x106,0x102,0x0ff,0x0fb,0x0f8,
    0x0f4,0x0f1,0x0ed,0x0ea,0x0e7,0x0e3,0x0e0,0x0dc,0x0d9,0x0d6,0x0d2,0x0cf,0x0cc,0x0c8,0x0c5,0x0c2,
    0x0be,0x0bb,0x0b8,0x0b5,0x0b1,0x0ae,0x0ab,0x0a8,0x0a4,0x0a1,0x09e,0x09b,0x098,0x094,0x091,0x08e,
    0x08b,0x088,0x085,0x082,0x07e,0x07b,0x078,0x075,0x072,0x06f,0x06c,0x069,0x066,0x063,0x060,0x05d,
    0x05a,0x057,0x054,0x051,0x04e,0x04b,0x048,0x045,0x042,0x03f,0x03c,0x039,0x036,0x033,0x030,0x02d,
    0x02a,0x028,0x025,0x022,0x01f,0x01c,0x019,0x016,0x014,0x011,0x00e,0x00b,0x008,0x006,0x003,0x000
};
static const uint32_t inc_tab[64] = {
    0x00000000, 0x00000000, 0x10101010, 0x10101010, 0x10101010, 0x10101010, 0x11101110, 0x11101110,
    0x10101010, 0x10111010, 0x11101110, 0x11111110, 0x10101010, 0x10111010, 0x11101110, 0x11111110,
    0x10101010, 0x10111010, 0x11101110, 0x11111110, 0x10101010, 0x10111010, 0x11101110, 0x11111110,
    0x10101010, 0x10111010, 0x11101110, 0x11111110, 0x10101010, 0x10111010, 0x11101110, 0x11111110,
    0x10101010, 0x10111010, 0x11101110, 0x11111110, 0x10101010, 0x10111010, 0x11101110, 0x11111110,
    0x10101010, 0x10111010, 0x11101110, 0x11111110, 0x10101010, 0x10111010, 0x11101110, 0x11111110,
    0x11111111, 0x21112111, 0x21212121, 0x22212221, 0x22222222, 0x42224222, 0x42424242, 0x44424442,
    0x44444444, 0x84448444, 0x84848484, 0x88848884, 0x88888888, 0x88888888, 0x88888888, 0x88888888
};
static const uint8_t detune_tab[32][4] = {
    {0,0,1,2},{0,0,1,2},{0,0,1,2},{0,0,1,2},{0,1,2,2},{0,1,2,3},{0,1,2,3},{0,1,2,3},
    {0,1,2,4},{0,1,3,4},{0,1,3,4},{0,1,3,5},{0,2,4,5},{0,2,4,6},{0,2,4,6},{0,2,5,7},
    {0,2,5,8},{0,3,6,8},{0,3,6,9},{0,3,7,10},{0,4,8,11},{0,4,8,12},{0,4,9,13},{0,5,10,14},
    {0,5,11,16},{0,6,12,17},{0,6,13,19},{0,7,14,20},{0,8,16,22},{0,8,16,22},{0,8,16,22},{0,8,16,22}
};
/* algorithms: inputs of operators 2, 3, 4 (0: none, 1-3: O1-O3, 5: O1+O2,
   6: O1+O3, 7: O2+O3) and which of O1-O3 are output too */
static const uint8_t alg_in[8][3] = {
    {1,2,3},{0,5,3},{0,2,6},{1,0,7},{1,0,3},{1,1,1},{1,0,0},{0,0,0}
};
static const uint8_t alg_out[8][3] = {
    {0,0,0},{0,0,0},{0,0,0},{0,0,0},{0,1,0},{0,1,1},{0,1,1},{1,1,1}
};
static const int slot_reg[4] = { 0, 8, 4, 12 };     /* slots 1-4 -> register offset */

enum { ATTACK, DECAY, SUSTAIN, RELEASE };

typedef struct {
    uint32_t phase;                     /* 10.10 */
    uint32_t att;                       /* 10-bit envelope attenuation */
    int state, keyon;
} Op;

typedef struct {
    uint8_t regs[256];
    Op op[3][4];
    int32_t fb[3][2];
    /* SSG */
    double tone_pos[3];
    uint32_t noise_lfsr;
    double noise_pos;
    int noise_out;
} Chip;

static Chip chips[2];
static uint32_t env_counter;

static uint32_t keycode(int bf) { return ((bf >> 10) & 15) << 1 | ((0xfe80 >> ((bf >> 7) & 15)) & 1); }

static uint32_t phase_step(Chip *c, int ch, int slot)
{
    int bf = (c->regs[0xA4 + ch] & 0x3f) << 8 | c->regs[0xA0 + ch];
    uint32_t fnum = (bf & 0x7ff) << 1, block = (bf >> 11) & 7;
    uint32_t step = (fnum << block) >> 2;
    int r = c->regs[0x30 + ch + slot_reg[slot]];
    int det = r >> 4 & 7;
    int adj = detune_tab[keycode(bf)][det & 3];
    step += (det & 4) ? -adj : adj;
    step &= 0x1ffff;
    uint32_t mul = (r & 15) * 2;
    if (!mul) mul = 1;
    return (step * mul) >> 1;
}

static uint32_t eg_rate(Chip *c, int ch, int slot, int state)
{
    int o = ch + slot_reg[slot];
    int bf = (c->regs[0xA4 + ch] & 0x3f) << 8 | c->regs[0xA0 + ch];
    uint32_t ksr = keycode(bf) >> ((c->regs[0x50 + o] >> 6) ^ 3);
    uint32_t raw;
    switch (state) {
    case ATTACK: raw = (c->regs[0x50 + o] & 31) * 2; break;
    case DECAY: raw = (c->regs[0x60 + o] & 31) * 2; break;
    case SUSTAIN: raw = (c->regs[0x70 + o] & 31) * 2; break;
    default: raw = (c->regs[0x80 + o] & 15) * 4 + 2; break;
    }
    if (!raw) return 0;
    return raw + ksr > 63 ? 63 : raw + ksr;
}

static void clock_env(Chip *c, int ch, int slot, uint32_t counter)
{
    Op *op = &c->op[ch][slot];
    int o = ch + slot_reg[slot];
    uint32_t sl = c->regs[0x80 + o] >> 4;
    sl |= (sl + 1) & 0x10;
    sl <<= 5;
    if (op->state == ATTACK && op->att == 0) op->state = DECAY;
    if (op->state == DECAY && op->att >= sl) op->state = SUSTAIN;
    uint32_t rate = eg_rate(c, ch, slot, op->state);
    uint32_t shift = rate >> 2;
    counter <<= shift;
    if (counter & 0x7ff) return;
    uint32_t bits = (counter >> (shift <= 11 ? 11 : shift)) & 7;
    uint32_t inc = (inc_tab[rate] >> (4 * bits)) & 15;
    if (op->state == ATTACK) {
        if (rate < 62) op->att += (~op->att * inc) >> 4;
    } else {
        op->att += inc;
        if (op->att >= 0x400) op->att = 0x3ff;
    }
    op->att &= 0x3ff;   /* (attack arithmetic wraps as in ymfm's uint32) */
}

static int32_t op_volume(Chip *c, int ch, int slot, uint32_t phase)
{
    Op *op = &c->op[ch][slot];
    uint32_t env = op->att + ((c->regs[0x40 + ch + slot_reg[slot]] & 0x7f) << 3);
    if (env > 0x3ff) env = 0x3ff;
    if (op->att > EG_QUIET) return 0;
    phase &= 0x3ff;
    uint32_t i = phase & 0x1ff;
    if (i & 0x100) i = ~i;
    uint32_t a = sin_tab[i & 0xff] + (env << 2);
    int32_t v = pow_tab[a & 0xff] >> (a >> 8);
    return (phase & 0x200) ? -v : v;
}

static void key(Chip *c, int ch, int mask)
{
    for (int s = 0; s < 4; s++) {
        Op *op = &c->op[ch][s];
        int on = mask >> s & 1;
        if (on && !op->keyon) {
            op->state = ATTACK;
            op->phase = 0;
            if (eg_rate(c, ch, s, ATTACK) >= 62) op->att = 0;
        } else if (!on && op->keyon) {
            op->state = RELEASE;
        }
        op->keyon = on;
    }
}

static void write_reg(Chip *c, int reg, int val)
{
    c->regs[reg] = val;
    if (reg == 0x28 && (val & 3) != 3) key(c, val & 3, val >> 4);
}

/* FM of one chip channel for an output sample */
static int32_t fm_channel(Chip *c, int ch)
{
    int alg = c->regs[0xB0 + ch] & 7, fb = c->regs[0xB0 + ch] >> 3 & 7;
    int32_t out[8] = {0};
    int32_t mod = fb ? (c->fb[ch][0] + c->fb[ch][1]) >> (10 - fb) : 0;
    out[1] = op_volume(c, ch, 0, (c->op[ch][0].phase >> 10) + mod);
    c->fb[ch][0] = c->fb[ch][1];
    c->fb[ch][1] = out[1];
    out[2] = op_volume(c, ch, 1, (c->op[ch][1].phase >> 10) + (out[alg_in[alg][0]] >> 1));
    out[5] = out[1] + out[2];
    out[3] = op_volume(c, ch, 2, (c->op[ch][2].phase >> 10) + (out[alg_in[alg][1]] >> 1));
    out[6] = out[1] + out[3];
    out[7] = out[2] + out[3];
    int32_t r = op_volume(c, ch, 3, (c->op[ch][3].phase >> 10) + (out[alg_in[alg][2]] >> 1));
    if (alg_out[alg][0]) r += out[1];
    if (alg_out[alg][1]) r += out[2];
    if (alg_out[alg][2]) r += out[3];
    if (r > 8191) r = 8191;
    if (r < -8192) r = -8192;
    return r;
}

/* the AY-style volume curve (as ymfm's SSG: 0, then about 3 dB a step) */
static double ssg_amp(int v) { return v ? pow(10.0, -(15 - v) * 3.0 / 20.0) : 0.0; }

static double ssg_sample(Chip *c, double dt)
{
    double out = 0;
    double ssg_clock = CLOCK / 2.0;     /* (prescaler 6: the SSG at clock / 2) */
    int nper = c->regs[6] & 31;
    if (!nper) nper = 1;
    c->noise_pos += dt * ssg_clock / 16.0 / nper;
    while (c->noise_pos >= 1) {
        c->noise_pos -= 1;
        c->noise_lfsr ^= (((c->noise_lfsr & 1) ^ ((c->noise_lfsr >> 3) & 1)) << 17);
        c->noise_lfsr >>= 1;
        c->noise_out = c->noise_lfsr & 1;
    }
    for (int ch = 0; ch < 3; ch++) {
        int per = (c->regs[ch * 2 + 1] & 15) << 8 | c->regs[ch * 2];
        if (!per) per = 1;
        double f = ssg_clock / 16.0 / per;
        c->tone_pos[ch] += f * dt;
        c->tone_pos[ch] -= floor(c->tone_pos[ch]);
        int tone = c->tone_pos[ch] < 0.5;
        int tone_off = c->regs[7] >> ch & 1, noise_off = c->regs[7] >> (ch + 3) & 1;
        int on = (tone | tone_off) & (c->noise_out | noise_off);
        int vol = c->regs[8 + ch] & 15;
        out += on ? ssg_amp(vol) : 0;
    }
    return out;
}

typedef struct { double t; int chip, reg, val; } Write;

int main(int argc, char **argv)
{
    if (argc < 5) { fprintf(stderr, "usage: fm_lite log.txt seconds rate out.wav\n"); return 1; }
    for (int i = 0; i < 256; i++) pow_tab[i] = (pow_src[i] | 0x400) << 2;
    Write *log = NULL;
    size_t n = 0, cap = 0;
    FILE *f = fopen(argv[1], "r");
    if (!f) { perror(argv[1]); return 1; }
    Write w;
    while (fscanf(f, "%lf %d %x %x", &w.t, &w.chip, &w.reg, &w.val) == 4) {
        if (n == cap) log = realloc(log, (cap = cap ? cap * 2 : 4096) * sizeof *log);
        log[n++] = w;
    }
    fclose(f);
    double seconds = atof(argv[2]), rate = atof(argv[3]);
    for (int k = 0; k < 2; k++) {
        memset(&chips[k], 0, sizeof chips[k]);
        chips[k].noise_lfsr = 1;
        for (int ch = 0; ch < 3; ch++)
            for (int s = 0; s < 4; s++) { chips[k].op[ch][s].att = 0x3ff; chips[k].op[ch][s].state = RELEASE; }
    }
    long total = (long)(seconds * rate);
    short *out = malloc(total * sizeof *out);
    double native = 0;                  /* FM native samples to run */
    size_t next = 0;
    double ssg_gain = getenv("SSG_GAIN") ? atof(getenv("SSG_GAIN")) : 1.0, fm_gain = 1.0 / 8192;
    /* CHUNK=n: as the 68k would - register writes taken every n samples, and
       the envelopes stepped once a chunk by their average rates */
    int chunk = getenv("CHUNK") ? atoi(getenv("CHUNK")) : 0;
    double avg[64];                     /* attenuation steps per envelope clock */
    for (int r = 0; r < 64; r++) {
        uint32_t shift = r >> 2;
        double sum = 0;
        for (uint32_t cnt = 0; cnt < 1 << 14; cnt++) {
            uint32_t c = cnt << shift;
            if (c & 0x7ff) continue;
            uint32_t bits = (c >> (shift <= 11 ? 11 : shift)) & 7;
            sum += (inc_tab[r] >> (4 * bits)) & 15;
        }
        avg[r] = sum / (1 << 14);
    }
    double frac[2][3][4] = {{{0}}};
    for (long i = 0; i < total; i++) {
        double t = i / rate;
        if (!chunk || i % chunk == 0) {
            double tw = chunk ? (i + chunk) / rate : t;
            while (next < n && log[next].t <= tw) {
                write_reg(&chips[log[next].chip & 1], log[next].reg, log[next].val);
                next++;
            }
        }
        if (chunk) {
            if (i % chunk == 0) {           /* the chunk's envelope clocks at once */
                double clocks = chunk * FM_RATE / rate / 3;
                for (int k = 0; k < 2; k++)
                    for (int ch = 0; ch < 3; ch++)
                        for (int s2 = 0; s2 < 4; s2++) {
                            Chip *c = &chips[k];
                            Op *op = &c->op[ch][s2];
                            int o = ch + slot_reg[s2];
                            uint32_t sl = c->regs[0x80 + o] >> 4;
                            sl |= (sl + 1) & 0x10;
                            sl <<= 5;
                            if (op->state == ATTACK && op->att == 0) op->state = DECAY;
                            if (op->state == DECAY && op->att >= sl) op->state = SUSTAIN;
                            uint32_t r = eg_rate(c, ch, s2, op->state);
                            if (op->state == ATTACK) {
                                if (r >= 62) op->att = 0;
                                else if (r) {
                                    double a = (op->att + 1) * pow(1 - avg[r] / 16, clocks) - 1;
                                    op->att = a < 0 ? 0 : (uint32_t)a;
                                }
                            } else {
                                frac[k][ch][s2] += avg[r] * clocks;
                                uint32_t d = (uint32_t)frac[k][ch][s2];
                                frac[k][ch][s2] -= d;
                                op->att += d;
                                if (op->att > 0x3ff) op->att = 0x3ff;
                            }
                        }
            }
            for (int k = 0; k < 2; k++)
                for (int ch = 0; ch < 3; ch++)
                    for (int s2 = 0; s2 < 4; s2++)
                        chips[k].op[ch][s2].phase += (uint32_t)(phase_step(&chips[k], ch, s2) * FM_RATE / rate);
        } else {
        /* the chip's own time: envelopes and phases stepped per native sample */
        native += FM_RATE / rate;
        while (native >= 1) {
            native -= 1;
            if ((++env_counter & 3) == 3) env_counter++;
            for (int k = 0; k < 2; k++)
                for (int ch = 0; ch < 3; ch++)
                    for (int s = 0; s < 4; s++) {
                        if ((env_counter & 3) == 0) clock_env(&chips[k], ch, s, env_counter >> 2);
                        chips[k].op[ch][s].phase += phase_step(&chips[k], ch, s);
                    }
        }
        }
        double v = 0;
        for (int k = 0; k < 2; k++) {
            for (int ch = 0; ch < 3; ch++) v += fm_channel(&chips[k], ch) * fm_gain;
            v += ssg_sample(&chips[k], 1.0 / rate) * ssg_gain * 0.25;
        }
        v *= 0.3;
        if (v > 1) v = 1;
        if (v < -1) v = -1;
        out[i] = (short)(v * 32000);
    }
    FILE *o = fopen(argv[4], "wb");
    uint32_t r = (uint32_t)rate, bytes = total * 2;
    unsigned char h[44] = {'R','I','F','F',0,0,0,0,'W','A','V','E','f','m','t',' ',16,0,0,0,1,0,1,0,
                           0,0,0,0,0,0,0,0,2,0,16,0,'d','a','t','a',0,0,0,0};
    uint32_t vals[4] = {36 + bytes, r, r * 2, bytes};
    int at[4] = {4, 24, 28, 40};
    for (int k = 0; k < 4; k++) for (int b = 0; b < 4; b++) h[at[k] + b] = vals[k] >> (8 * b);
    fwrite(h, 1, 44, o);
    fwrite(out, 2, total, o);
    fclose(o);
    return 0;
}
