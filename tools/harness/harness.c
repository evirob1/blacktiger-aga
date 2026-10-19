/* Black Tiger AGA - translation test harness.
 *
 * Runs the translated game (src/harness_main.s, translated with --cycles) on
 * the Musashi 68020 core. The game runs continuously like the arcade board:
 * a5 counts Z80 T-states, and the harness raises the Z80 interrupt every
 * 100608 T-states (one MAME frame), at a Z80 instruction boundary (nop marker)
 * while the game has interrupts enabled, honouring the one-instruction delay
 * after ei.
 *
 * I/O reads are replayed from a MAME recording (tools/mame/record.lua), and
 * the game RAM is compared with MAME's every time the interrupt reads its
 * vblank flag - the moment MAME took its snapshot.
 *
 * usage: harness game.bin io.txt ram.bin [max_vblanks]
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "m68k.h"

#define MEMSIZE 0x01000000
#define BASE    0x00010000
#define STACK   0x00f00000
#define EXC     0x00f80100
#define REC_SIZE (0x2000 + 0x4000 + 0x800 + 0x800)
#define FRAME_T 100608u      /* Z80 T-states per frame: 384 x 262 */
#define FIRST_IRQ 100608u    /* measured: interrupt at the start of each frame */

#define RT_IE 2

static unsigned char mem[MEMSIZE];
static unsigned int z80mem_off, bgram_off, vars_off, irq_off;
static int done, failed;

#define MAXQ 2000000
static unsigned char *q[256];
static int *qv[256];
static int qn[256], qpos[256];

static FILE *ramf;
static unsigned char rec[REC_SIZE];
static int frames_ok, max_frames = 1 << 30;

static unsigned int next_irq = FIRST_IRQ;
static int armed;            /* an instruction has completed since ei */
static unsigned int irq_handler;
static unsigned long long irqs;
static unsigned int trace_lo, trace_hi;   /* BT_TRACE=lo,hi: log boundaries in this T-state range */
static FILE *trace_f;

static void stop(int fail)
{
    done = 1;
    if (fail) failed = 1;
    m68k_end_timeslice();
}

static unsigned int rd8(unsigned int a) { return mem[a & (MEMSIZE - 1)]; }
static unsigned int rd16(unsigned int a) { return rd8(a) << 8 | rd8(a + 1); }
static unsigned int rd32(unsigned int a) { return rd16(a) << 16 | rd16(a + 2); }

static int z80(unsigned int addr)
{
    return BASE + z80mem_off + 0x8000 + (short)(addr & 0xffff);
}

static void compare(int vbl)
{
    unsigned char cur[REC_SIZE];
    int i, n = 0;
    if (fread(rec, 1, REC_SIZE, ramf) != REC_SIZE) {
        printf("end of the MAME recording at vblank %d\n", vbl);
        stop(0);
        return;
    }
    for (i = 0; i < 0x2000; i++) cur[i] = mem[z80(0xe000 + i)];
    memcpy(cur + 0x2000, mem + BASE + bgram_off, 0x4000);
    int bank = mem[BASE + vars_off + 1] & 3;
    for (i = 0; i < 0x1000; i++) cur[0x2000 + bank * 0x1000 + i] = mem[z80(0xc000 + i)];
    for (i = 0; i < 0x1000; i++) cur[0x6000 + i] = mem[z80(0xd000 + i)];
    for (i = 0; i < REC_SIZE; i++) {
        int a = i < 0x2000 ? 0xe000 + i : -1;
        if (cur[i] == rec[i]) continue;
        /* Z80 stacks and the saved-SP bytes of task slots are not modelled */
        if (a >= 0xe300 && a < 0xe580) continue;
        if (a >= 0xe600 && a < 0xe880) continue;
        if (a >= 0xe880 && a < 0xe900 && (a & 7) >= 2 && (a & 7) <= 3) continue;
        if (n < 24) {
            if (a >= 0) printf("  Z80 $%04x: MAME %02x  translated %02x\n", a, rec[i], cur[i]);
            else if (i < 0x6000) printf("  bg RAM +$%04x: MAME %02x  translated %02x\n", i - 0x2000, rec[i], cur[i]);
            else printf("  $%04x: MAME %02x  translated %02x\n", 0xd000 + i - 0x6000, rec[i], cur[i]);
        }
        n++;
    }
    if (n) {
        printf("vblank %d: %d bytes differ (after %d matching vblanks)\n", vbl, n, frames_ok);
        stop(1);
        return;
    }
    frames_ok++;
    if (frames_ok >= max_frames) stop(0);
}

/* BT_PROFILE: 68k cycles spent on game work per frame (not the idle loop and
   not the test build's nop/lea instrumentation) */
static int profile;
static unsigned long long work_cyc;
static unsigned int idle_lo, idle_hi;
static unsigned int work_hist[100000];
static int work_n;
static unsigned int pc_cyc[1 << 22];     /* BT_PROFILE: work cycles per 68k address */

/* called by Musashi before every instruction */
void harness_hook(unsigned int pc)
{
    if (pc == irq_handler) { m68k_set_irq(0); return; }
    if (rd16(pc) != 0x4e71) return;                 /* not a Z80 instruction boundary */
    if (trace_lo) {
        unsigned int t0 = m68k_get_reg(NULL, M68K_REG_A5);
        if (t0 >= trace_lo && t0 <= trace_hi) fprintf(trace_f, "%u %x\n", t0, pc - BASE);
    }
    if (!mem[BASE + vars_off + RT_IE]) { armed = 0; return; }
    if (!armed) { armed = 1; return; }               /* the instruction after ei */
    unsigned int t = m68k_get_reg(NULL, M68K_REG_A5);
    if ((int)(t - next_irq) >= 0) {
        next_irq += FRAME_T;
        armed = 0;
        irqs++;
        if (profile && work_n < 100000) { work_hist[work_n++] = (unsigned int)work_cyc; work_cyc = 0; }
        if (getenv("BT_TRACE_IRQ")) printf("irq at T=%u pc=%06x\n", t, pc - BASE);
        m68k_set_irq(3);
        m68k_end_timeslice();          /* Musashi takes interrupts between slices */
    }
}

/* the Z80 image's $8000-$BFFF is never filled (bank reads go through a1):
   reading it means a bank-read site is missing from data/bank_reads.txt.
   The harness answers with the right bank data, notes the 68k address
   (STALE lines, see tools/harness/stale_sites.py) and fails at the end. */
static unsigned int banks_off;
static int stale_reads;
static unsigned int stale_pcs[4096];
static int stale_n;

static int stale_fix(unsigned int a, unsigned int *v, int size)
{
    unsigned int w = BASE + z80mem_off;
    if (a < w || a >= w + 0x4000) return 0;
    unsigned int pc = m68k_get_reg(NULL, M68K_REG_PPC) - BASE;
    int k;
    for (k = 0; k < stale_n && stale_pcs[k] != pc; k++) ;
    if (k == stale_n && stale_n < 4096) stale_pcs[stale_n++] = pc;
    stale_reads++;
    unsigned int src = BASE + banks_off + mem[BASE + vars_off] * 0x4000 + (a - w);
    *v = size == 1 ? rd8(src) : size == 2 ? rd16(src) : rd32(src);
    return 1;
}

unsigned int m68k_read_memory_8(unsigned int a)
{
    if ((a & 0xffff00) == 0xff0000) {
        int port = a & 0xff;
        if (getenv("BT_IOLOG")) printf("IO %x %u\n", port, m68k_get_reg(NULL, M68K_REG_A5));
        if (qpos[port] >= qn[port]) {
            printf("I/O replay: no more recorded reads of port %02x\n", port);
            stop(qn[port] == 0);
            return 0xff;
        }
        int i = qpos[port]++;
        if (qv[port][i]) compare(qv[port][i]);
        return q[port][i];
    }
    unsigned int v;
    if (stale_fix(a, &v, 1)) return v;
    return rd8(a);
}
unsigned int m68k_read_memory_16(unsigned int a) { unsigned int v; return stale_fix(a, &v, 2) ? v : rd16(a); }
unsigned int m68k_read_memory_32(unsigned int a) { unsigned int v; return stale_fix(a, &v, 4) ? v : rd32(a); }
unsigned int m68k_read_disassembler_16(unsigned int a) { return rd16(a); }
unsigned int m68k_read_disassembler_32(unsigned int a) { return rd32(a); }

void m68k_write_memory_8(unsigned int a, unsigned int v)
{
    if ((a & 0xffff00) == 0xff0100) {                /* port writes */
        if (getenv("BT_IOLOG")) printf("IO %x %u\n", a & 0xff, m68k_get_reg(NULL, M68K_REG_A5));
        return;
    }
    if (a == 0xff0400) {                               /* exception */
        unsigned int sp = m68k_get_reg(NULL, M68K_REG_SP);
        printf("68k exception (vector %u) at %06x (offset in game.bin)\n",
               (rd16(sp + 6) & 0xfff) / 4, rd32(sp + 2) - BASE);
        stop(1);
        return;
    }
    if (a == BASE + vars_off + RT_IE) armed = 0;       /* di or ei */
    mem[a & (MEMSIZE - 1)] = v;
}
void m68k_write_memory_16(unsigned int a, unsigned int v)
{
    m68k_write_memory_8(a, v >> 8);
    m68k_write_memory_8(a + 1, v & 0xff);
}
void m68k_write_memory_32(unsigned int a, unsigned int v)
{
    if (a == 0xff0300) {
        printf("computed jump to a Z80 address with no translation: bank %02x addr $%04x\n",
               (v >> 16) & 0xff, v & 0xffff);
        stop(1);
        return;
    }
    m68k_write_memory_16(a, v >> 16);
    m68k_write_memory_16(a + 2, v & 0xffff);
}

int main(int argc, char **argv)
{
    if (argc < 4) { fprintf(stderr, "usage: harness game.bin io.txt ram.bin [max_vblanks]\n"); return 1; }
    if (argc > 4) max_frames = atoi(argv[4]);
    FILE *f = fopen(argv[1], "rb");
    if (!f) { perror(argv[1]); return 1; }
    size_t len = fread(mem + BASE, 1, MEMSIZE - BASE - 0x200000, f);
    fclose(f);
    z80mem_off = rd32(BASE + 8);
    bgram_off = rd32(BASE + 12);
    vars_off = rd32(BASE + 16);
    irq_off = rd32(BASE + 20);
    irq_handler = BASE + irq_off;
    banks_off = rd32(BASE + 32);

    f = fopen(argv[2], "r");
    if (!f) { perror(argv[2]); return 1; }
    for (int p = 0; p < 256; p++) { q[p] = malloc(MAXQ); qv[p] = calloc(MAXQ, sizeof(int)); }
    char line[64];
    int pending_v = 0;
    while (fgets(line, sizeof line, f)) {
        unsigned int p, v;
        int n;
        if (line[0] == 'V' && sscanf(line + 2, "%d", &n) == 1) pending_v = n;
        else if (line[0] == 'R' && sscanf(line + 2, "%x %x", &p, &v) == 2 && qn[p] < MAXQ) {
            if (p == 0 && pending_v) { qv[p][qn[p]] = pending_v; pending_v = 0; }
            q[p][qn[p]++] = v;
        }
    }
    fclose(f);
    ramf = fopen(argv[3], "rb");
    if (!ramf) { perror(argv[3]); return 1; }

    /* exceptions: move.b #1,$ff0400 / bra.s * ; level 3 autovector: the game's handler */
    static const unsigned char exc[] = {0x13, 0xfc, 0x00, 0x01, 0x00, 0xff, 0x04, 0x00, 0x60, 0xfe};
    memcpy(mem + EXC, exc, sizeof exc);
    for (int v = 2; v < 64; v++) {
        unsigned int h = v == 27 ? irq_handler : EXC;
        mem[v * 4] = h >> 24; mem[v * 4 + 1] = h >> 16; mem[v * 4 + 2] = h >> 8; mem[v * 4 + 3] = h;
    }
    mem[0] = STACK >> 24; mem[1] = STACK >> 16; mem[2] = STACK >> 8; mem[3] = STACK;
    mem[4] = BASE >> 24; mem[5] = BASE >> 16; mem[6] = BASE >> 8; mem[7] = BASE;

    printf("game.bin: %zu bytes\n", len);
    if (getenv("BT_TRACE")) {
        sscanf(getenv("BT_TRACE"), "%u,%u", &trace_lo, &trace_hi);
        trace_f = fopen("build/harness_trace.txt", "w");
    }
    m68k_init();
    m68k_set_cpu_type(M68K_CPU_TYPE_68020);
    m68k_pulse_reset();
    m68k_set_reg(M68K_REG_SR, 0x2000);
    unsigned long long cycles = 0;
    profile = getenv("BT_PROFILE") != NULL;
    idle_lo = BASE + rd32(BASE + 24);
    idle_hi = BASE + rd32(BASE + 28);
    while (!done) {
        if (profile) {
            /* one instruction at a time: m68k_execute returns its exact cycles */
            unsigned int pc = m68k_get_reg(NULL, M68K_REG_PC);
            unsigned int op = rd16(pc);
            int c = m68k_execute(1);
            cycles += c;
            int instr = op == 0x4e71 || op == 0x4bed;      /* test build's nop / lea d16(a5),a5 */
            int idle = pc >= idle_lo && pc < idle_hi;
            if (!instr && !idle) {
                work_cyc += c;
                if (pc - BASE < (1 << 22)) pc_cyc[pc - BASE] += c;
            }
        } else
            cycles += m68k_execute(1000000);
    }
    if (profile && work_n > 1) {
        /* frame 0 is the reset code */
        unsigned int *h = work_hist + 1;
        int n = work_n - 1;
        unsigned long long sum = 0;
        for (int i = 0; i < n; i++) sum += h[i];
        for (int i = 1; i < n; i++)
            for (int j = i; j > 0 && h[j - 1] > h[j]; j--) { unsigned int x = h[j]; h[j] = h[j - 1]; h[j - 1] = x; }
        printf("game work per frame (68k cycles, Musashi 68020 timing): mean %llu  median %u  p90 %u  p99 %u  max %u\n",
               sum / n, h[n / 2], h[n * 9 / 10], h[n * 99 / 100], h[n - 1]);
        FILE *pf = fopen("build/profile.txt", "w");
        for (unsigned int i = 0; i < (1 << 22); i++)
            if (pc_cyc[i]) fprintf(pf, "%x %u\n", i, pc_cyc[i]);
        fclose(pf);
    }
    if (stale_n) {
        printf("%d reads of the unfilled bank window from %d places (data/bank_reads.txt is incomplete):\n",
               stale_reads, stale_n);
        for (int k = 0; k < stale_n; k++) printf("STALE %x\n", stale_pcs[k]);
        failed = 1;
    }
    unsigned int t = m68k_get_reg(NULL, M68K_REG_A5);
    printf("%d vblanks matched MAME exactly; %llu interrupts; %.0f Z80 T-states/frame, "
           "%.0f 68k cycles/frame (Musashi's count, no wait states)\n",
           frames_ok, irqs, irqs ? (double)t / irqs : 0.0, irqs ? (double)cycles / irqs : 0.0);
    return failed;
}
