/* Black Tiger AGA - run the Amiga game build (build/game/game.bin) on Musashi
 * with a minimal stand-in for the A1200: custom chip reads return idle values,
 * the blitter is always ready, and the vertical blank interrupt (level 3) comes
 * every 283,750 68k cycles (a PAL frame at 14.19 MHz, no wait states).
 *
 * It reports, per second of Amiga time, how many cycles the vblank handler
 * used and how far the arcade program got (its frame counter at $E003), and
 * can dump the arcade text layer as ASCII-ish codes.
 *
 * usage: BT_RT_HEADER=<hex offset> amiga_sim game.bin seconds [dump_text_at_second ...]
 *        (tools/harness/amiga_sim.sh finds the offset)
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "m68k.h"

#define MEMSIZE 0x01000000
/* where the program is loaded: BT_FASTMODE=1 puts it in "fast RAM" at
   $800000 (no chip wait states) and passes a chip RAM block at $100000 in
   A3, as the bootblock does with fast RAM */
static unsigned int BASE = 0x00010000;
#define CHIPBLOCK 0x00100000
#define EXEC    0x00008000
static unsigned long long FRAME = 283750;  /* PAL; NTSC timing (BEAMCON0 = 0): 262 lines */
#define FPS (FRAME == 283750 ? 50 : 60)

static unsigned char mem[MEMSIZE];
static unsigned int z80mem_off, vars_off;
static int irq_pending;
static unsigned long long now;            /* 68k cycles */
static unsigned long long in_lev3, lev3_start;
static int in_irq;
static unsigned int lev3_addr;

/* chip RAM: BT_CHIPWAIT extra 68k cycles for every data access and every
   instruction fetch that misses the 68020's cache (64 longwords, direct
   mapped); BT_FASTRAM=hex address: from there on it's fast RAM (no wait) */
static unsigned long long xcyc;
static int chipwait;
static unsigned int fast_from = 0xffffffff;
static unsigned int ic_tag[64];
static unsigned long long T(void) { return now + m68k_cycles_run() + xcyc; }
static void waitd(unsigned int a) { if (a < fast_from || a >= 0xbf0000) xcyc += chipwait; }
static void fetch(unsigned int a)
{
    unsigned int l = (a >> 2) & 63, tag = a >> 8 | 0x80000000;
    if (ic_tag[l] != tag) { ic_tag[l] = tag; if (a < fast_from) xcyc += chipwait; }
}

static unsigned int rd8(unsigned int a) { return mem[a & (MEMSIZE - 1)]; }
static unsigned int rd16(unsigned int a) { return rd8(a) << 8 | rd8(a + 1); }
static unsigned int rd32(unsigned int a) { return rd16(a) << 16 | rd16(a + 2); }

/* the blitter takes 1 memory cycle per word per channel used (at least 2),
   BLIT_CYC 68k cycles each (a colour clock is 4; the rest for display DMA) */
static int BLIT_CYC = 6;                /* BT_BLIT_CYC overrides */
static unsigned long long blit_busy;

static unsigned int custom_read(unsigned int reg)
{
    switch (reg & 0x1fe) {
    case 0x002: return T() < blit_busy ? 0x4000 : 0;   /* DMACONR: BBUSY */
    case 0x004: return 0;                          /* VPOSR */
    case 0x006: return (unsigned int)(now / 64) & 0xffff;   /* VHPOSR moves */
    case 0x016: return 0xffff;                     /* POTINP: buttons up */
    case 0x01e: return irq_pending ? 0x0020 : 0;   /* INTREQR */
    default: return 0;
    }
}

/* reads of the Z80 image's unfilled bank window: a bank-read site missing
   from data/bank_reads.txt (printed as STALE <68k offset>, once each) */
static unsigned int stale_seen[4096];
static int stale_n;
/* the Z80 image's background RAM window $C000-$CFFF is unused (translated
   code addresses the current bank in bgram): print each instruction (68k
   offset) that touches it anyway, once - a site missing from data/bg_stores.txt */
static unsigned int bg_seen[8192];
static int bg_n, bgsites = -1;
static void bg_check(unsigned int a)
{
    if (bgsites < 0) bgsites = 1;
    if (!bgsites || !z80mem_off) return;
    unsigned int w = BASE + z80mem_off + 0x4000;
    if (a < w || a >= w + 0x1000) return;
    unsigned int pc = m68k_get_reg(NULL, M68K_REG_PPC) - BASE;
    for (int i = 0; i < bg_n; i++) if (bg_seen[i] == pc) return;
    if (bg_n < 8192) bg_seen[bg_n++] = pc;
    printf("BGSTALE %x\n", pc);
}

static void stale_check(unsigned int a)
{
    bg_check(a);
    if (!z80mem_off) return;
    unsigned int w = BASE + z80mem_off;
    if (a < w || a >= w + 0x4000) return;
    unsigned int pc = m68k_get_reg(NULL, M68K_REG_PPC) - BASE;
    for (int i = 0; i < stale_n; i++) if (stale_seen[i] == pc) return;
    if (stale_n < 4096) stale_seen[stale_n++] = pc;
    printf("STALE %x\n", pc);
}

unsigned int m68k_read_memory_8(unsigned int a)
{
    a &= 0xffffff;
    waitd(a);
    stale_check(a);
    if (a >= 0xdff000 && a < 0xdff200) return (a & 1) ? custom_read(a) & 0xff : custom_read(a) >> 8;
    if (a >= 0xbfd000 && a < 0xbff000) return 0xff;
    return rd8(a);
}
unsigned int m68k_read_memory_16(unsigned int a)
{
    a &= 0xffffff;
    waitd(a);
    stale_check(a);
    if (a >= 0xdff000 && a < 0xdff200) return custom_read(a);
    return rd16(a);
}
unsigned int m68k_read_memory_32(unsigned int a) { xcyc -= (a & 0xffffff) < fast_from ? chipwait : 0; return m68k_read_memory_16(a) << 16 | m68k_read_memory_16(a + 2); }
unsigned int m68k_read_immediate_16(unsigned int a) { fetch(a & 0xffffff); return rd16(a & 0xffffff); }
unsigned int m68k_read_immediate_32(unsigned int a) { fetch(a & 0xffffff); fetch((a + 2) & 0xffffff); return rd32(a & 0xffffff); }
unsigned int m68k_read_pcrelative_8(unsigned int a) { return m68k_read_memory_8(a); }
unsigned int m68k_read_pcrelative_16(unsigned int a) { return m68k_read_memory_16(a); }
unsigned int m68k_read_pcrelative_32(unsigned int a) { return m68k_read_memory_32(a); }
unsigned int m68k_read_disassembler_16(unsigned int a) { return rd16(a); }
unsigned int m68k_read_disassembler_32(unsigned int a) { return rd32(a); }

/* the blitter (area mode): channels A-D, shifts, first/last word masks, minterm */
static unsigned int blt[0x100];
static void blit(void)
{
    unsigned int con0 = blt[0x40 / 2], con1 = blt[0x42 / 2];
    unsigned int apt = blt[0x50 / 2] << 16 | blt[0x52 / 2];
    unsigned int bpt = blt[0x4c / 2] << 16 | blt[0x4e / 2];
    unsigned int cpt = blt[0x48 / 2] << 16 | blt[0x4a / 2];
    unsigned int dpt = blt[0x54 / 2] << 16 | blt[0x56 / 2];
    int amod = (short)blt[0x64 / 2], bmod = (short)blt[0x62 / 2];
    int cmod = (short)blt[0x60 / 2], dmod = (short)blt[0x66 / 2];
    unsigned int afwm = blt[0x44 / 2], alwm = blt[0x46 / 2];
    unsigned int adat = blt[0x74 / 2], bdat = blt[0x72 / 2], cdat = blt[0x70 / 2];
    int ash = con0 >> 12, bsh = con1 >> 12, mt = con0 & 0xff;
    unsigned int size = blt[0x58 / 2];
    int h = size >> 6 ? size >> 6 : 1024, w = size & 63 ? size & 63 : 64;
    unsigned int aold = 0, bold = 0;
    if (con1 & 1) { printf("line mode blit not emulated\n"); exit(1); }
    int nch = !!(con0 & 0x800) + !!(con0 & 0x400) + !!(con0 & 0x200) + !!(con0 & 0x100);
    blit_busy = T() + (unsigned long long)h * w * (nch < 2 ? 2 : nch) * BLIT_CYC;
    for (int y = 0; y < h; y++) {
        for (int x = 0; x < w; x++) {
            unsigned int a = adat, b = bdat, c = cdat, d = 0;
            if (con0 & 0x0800) { a = rd16(apt); apt += 2; }
            if (con0 & 0x0400) { b = rd16(bpt); bpt += 2; }
            if (con0 & 0x0200) { c = rd16(cpt); cpt += 2; }
            if (x == 0) a &= afwm;
            if (x == w - 1) a &= alwm;
            unsigned int as = ((aold << 16 | a) >> ash) & 0xffff;
            unsigned int bs = ((bold << 16 | b) >> bsh) & 0xffff;
            aold = a;
            bold = b;
            for (int n = 0; n < 8; n++)
                if (mt >> n & 1)
                    d |= (n & 4 ? as : ~as) & (n & 2 ? bs : ~bs) & (n & 1 ? c : ~c);
            if (con0 & 0x0100) {
                mem[dpt & 0xffffff] = d >> 8;
                mem[(dpt + 1) & 0xffffff] = d;
                dpt += 2;
            }
        }
        if (con0 & 0x0800) apt += amod;
        if (con0 & 0x0400) bpt += bmod;
        if (con0 & 0x0200) cpt += cmod;
        if (con0 & 0x0100) dpt += dmod;
    }
}

static void custom_write(unsigned int reg, unsigned int v)
{
    blt[(reg & 0x1fe) / 2] = v;
    if ((reg & 0x1fe) == 0x1dc && !(v & 0x20)) FRAME = 262ULL * 227 * 4;
    if ((reg & 0x1fe) == 0x058) blit();
    if ((reg & 0x1fe) == 0x09c && !(v & 0x8000) && (v & 0x20)) {  /* INTREQ clear VERTB */
        irq_pending = 0;
        m68k_set_irq(0);
    }
    if ((reg & 0x1fe) == 0x180 && v == 0x0b00) {      /* z80_bad_jump's red screen */
        unsigned int d7 = m68k_get_reg(NULL, M68K_REG_D7);
        printf("red screen: computed jump to untranslated Z80 code: bank %02x address $%04x\n", (d7 >> 16) & 0xff, d7 & 0xffff);
        char dn[256];
        snprintf(dn, sizeof dn, "%s_red.bin", getenv("BT_DUMP") ? getenv("BT_DUMP") : "build/amiga_mem");
        FILE *df = fopen(dn, "wb");
        fwrite(mem, 1, BASE > 0x10000 ? MEMSIZE : 0x400000, df);
        fclose(df);
        exit(1);
    }
}

void m68k_write_memory_8(unsigned int a, unsigned int v)
{
    a &= 0xffffff;
    waitd(a);
    bg_check(a);
    if (a >= 0xdff000 && a < 0xdff200) return;
    if (a >= 0xbfd000 && a < 0xbff000) return;
    mem[a] = v;
}
void m68k_write_memory_16(unsigned int a, unsigned int v)
{
    a &= 0xffffff;
    waitd(a);
    bg_check(a);
    if (a >= 0xdff000 && a < 0xdff200) { custom_write(a, v); return; }
    mem[a] = v >> 8;
    mem[a + 1] = v;
}
void m68k_write_memory_32(unsigned int a, unsigned int v)
{
    xcyc -= (a & 0xffffff) < fast_from ? chipwait : 0;   /* one 32-bit access */
    m68k_write_memory_16(a, v >> 16);
    m68k_write_memory_16(a + 2, v & 0xffff);
}

/* BT_PROBES=a,b,c,...: hex offsets; reports the average cycles from each probe to the next */
static unsigned int probes[16];
static int nprobes, last_probe = -1;
static unsigned long long probe_t, probe_sum[16], probe_n[16];

static unsigned long long next_vbl = 283750;
static int vbl_due;

static unsigned int indisp_addr;          /* BT_INDISP: pv_indisp, the display context runs */
static unsigned long long disp_cycles, hook_last, disp_clock;   /* disp_clock: display time only */

/* scheduler idle loop (rt_header +24..+28) and BT_ROUTINE=start,end: time spent */
static unsigned int idle_lo, idle_hi, rt_start, rt_end;
static unsigned long long idle_cycles, rt_cycles, rt_t0, rt_calls, idle_last;
static int in_rt;

void harness_hook(unsigned int pc)
{
    {
        unsigned long long t = T();
        if (idle_lo && pc >= idle_lo && pc < idle_hi && !(indisp_addr && mem[indisp_addr])) idle_cycles += t - idle_last;
        idle_last = t;
        if (rt_start && pc == rt_start && !in_rt) { in_rt = 1; rt_t0 = t; rt_calls++; }
        else if (in_rt && pc == rt_end) { in_rt = 0; rt_cycles += t - rt_t0; }
    }
    if (indisp_addr) {
        unsigned long long t = T();
        if (mem[indisp_addr]) { disp_cycles += t - hook_last; disp_clock += t - hook_last; }
        hook_last = t;
    }
    /* the vertical blank arrives at its exact cycle, between any two instructions */
    if (!vbl_due && T() >= next_vbl) {
        vbl_due = 1;
        irq_pending = 1;
        m68k_set_irq(3);
        m68k_end_timeslice();
    }
    for (int i = 0; i < nprobes; i++)
        if (pc == probes[i]) {
            unsigned long long t = indisp_addr ? disp_clock : T();   /* (display probes: its own time) */
            if (last_probe >= 0 && i == last_probe + 1) { probe_sum[last_probe] += t - probe_t; probe_n[last_probe]++; }
            last_probe = i;
            probe_t = t;
        }
    if (pc == lev3_addr && !in_irq) { in_irq = 1; lev3_start = T(); }
    if (in_irq && rd16(pc) == 0x4e73) {             /* rte */
        unsigned int sp = m68k_get_reg(NULL, M68K_REG_SP);
        (void)sp;
        in_lev3 += T() - lev3_start;
        in_irq = 0;
    }
}

static int z80(unsigned int addr) { return BASE + z80mem_off + 0x8000 + (short)(addr & 0xffff); }

/* every visible text cell: does the sprite data show what text RAM holds? */
static void check_text(void)
{
    unsigned int txspr = rd32(BASE + (unsigned int)strtoul(getenv("BT_CHIPA"), NULL, 16)) +
                         (unsigned int)strtoul(getenv("BT_CATXSPR"), NULL, 16);
    unsigned int chars = BASE + (unsigned int)strtoul(getenv("BT_CHARS"), NULL, 16);
    int bad = 0;
    for (int row = 2; row < 30; row++)
        for (int col = 0; col < 32; col++) {
            int cell = row * 32 + col;
            int attr = mem[z80(0xd400 + cell)];
            int code = mem[z80(0xd000 + cell)] | (attr & 0xe0) << 3;
            unsigned int spr = txspr + (col >> 3) * 2 * (16 + 224 * 16 + 16) + 16 + (row - 2) * 128 + (col & 7);
            unsigned int odd = spr + 16 + 224 * 16 + 16;   /* the cell is in one of the pair */
            for (int y = 0; y < 8; y++)
                if ((mem[spr + y * 16] | mem[odd + y * 16]) != mem[chars + code * 16 + y * 2] ||
                    (mem[spr + y * 16 + 8] | mem[odd + y * 16 + 8]) != mem[chars + code * 16 + y * 2 + 1]) {
                    if (bad < 10) printf("  text row %d col %d: char %03x not in the sprite data\n", row, col, code);
                    bad++;
                    break;
                }
        }
    printf("  text cells wrong in the sprites: %d\n", bad);
    if (getenv("BT_TXSHADOW")) {
        unsigned int sh = BASE + (unsigned int)strtoul(getenv("BT_TXSHADOW"), NULL, 16);
        int same = 0;
        for (int i = 64; i < 960; i++) same += mem[sh + i] == mem[z80(0xd000 + i)];
        printf("  renderer's copy of text RAM: %d of 896 codes match\n", same);
    }
}

static void dump_text(void)
{
    for (int row = 0; row < 32; row++) {
        printf("  %2d |", row);
        for (int col = 0; col < 32; col++) {
            int c = mem[z80(0xd000 + row * 32 + col)];
            putchar(c >= 0x20 && c < 0x7f ? c : (c == 0 ? ' ' : '.'));
        }
        printf("|\n");
    }
}

int main(int argc, char **argv)
{
    if (argc < 3) { fprintf(stderr, "usage: amiga_sim game.bin seconds [dump_at...]\n"); return 1; }
    FILE *f = fopen(argv[1], "rb");
    if (!f) { perror(argv[1]); return 1; }
    if (getenv("BT_FASTMODE")) { BASE = 0x800000; fast_from = 0x800000; }
    size_t len = fread(mem + BASE, 1, 0x400000, f);
    fclose(f);
    int seconds = atoi(argv[2]);
    /* the platform code starts with lea super(pc),a5 / jsr -30(a6): fake Supervisor */
    mem[EXEC - 30] = 0x4e; mem[EXEC - 29] = 0xd5;   /* jmp (a5) */
    /* rt_header offset: from the assembler listing (tools/harness/amiga_sim.sh) */
    unsigned int hdr = BASE + (unsigned int)strtoul(getenv("BT_RT_HEADER") ? getenv("BT_RT_HEADER") : "0", NULL, 16);
    z80mem_off = hdr - BASE + rd32(hdr + 8);
    vars_off = hdr - BASE + rd32(hdr + 16);

    mem[0] = 0; mem[1] = 0x0f; mem[2] = 0; mem[3] = 0;          /* SSP */
    mem[4] = BASE >> 24; mem[5] = BASE >> 16; mem[6] = BASE >> 8; mem[7] = BASE;
    if (getenv("BT_PROBES")) {
        char *p = getenv("BT_PROBES");
        while (*p && nprobes < 16) {
            probes[nprobes++] = BASE + (unsigned int)strtoul(p, &p, 16);
            if (*p == ',') p++;
        }
    }
    if (getenv("BT_BLIT_CYC")) BLIT_CYC = atoi(getenv("BT_BLIT_CYC"));
    if (getenv("BT_CHIPWAIT")) chipwait = atoi(getenv("BT_CHIPWAIT"));
    idle_lo = hdr + rd32(hdr + 24);
    idle_hi = hdr + rd32(hdr + 28);
    if (getenv("BT_ROUTINE")) {
        char *p = getenv("BT_ROUTINE");
        rt_start = BASE + (unsigned int)strtoul(p, &p, 16);
        if (*p == ',') rt_end = BASE + (unsigned int)strtoul(p + 1, NULL, 16);
    }
    if (getenv("BT_FASTRAM")) fast_from = (unsigned int)strtoul(getenv("BT_FASTRAM"), NULL, 16);
    if (getenv("BT_INDISP")) indisp_addr = BASE + (unsigned int)strtoul(getenv("BT_INDISP"), NULL, 16);
    m68k_init();
    m68k_set_cpu_type(M68K_CPU_TYPE_68020);
    m68k_pulse_reset();
    m68k_set_reg(M68K_REG_A6, EXEC);
    m68k_set_reg(M68K_REG_A3, BASE > 0x10000 ? CHIPBLOCK : 0);
    m68k_set_reg(M68K_REG_SR, 0x2000);           /* (the real Supervisor() call gets here) */

    unsigned long long next = FRAME;
    int frame = 0, dumpi = 3;
    unsigned int last_e003 = 0, z80_frames = 0;
    while (frame < seconds * FPS) {
        int c = m68k_execute(2000);
        now += c;
        if (!lev3_addr) lev3_addr = rd32(0x6c);
        if (vbl_due) {
            vbl_due = 0;
            next_vbl += FRAME;
            frame++;
            unsigned int e003 = mem[z80(0xe003)];
            z80_frames += (e003 - last_e003) & 0xff;
            last_e003 = e003;
            /* BT_KEYS="frame:key,frame:-key,...": Amiga raw key codes (hex) pressed/released */
            if (getenv("BT_KEYS") && getenv("BT_PVKEYS")) {
                unsigned int keys = BASE + (unsigned int)strtoul(getenv("BT_PVKEYS"), NULL, 16);
                char *p = getenv("BT_KEYS");
                while (*p) {
                    int f = (int)strtol(p, &p, 10);
                    if (*p == ':') p++;
                    int up = *p == '-';
                    if (up) p++;
                    int k = (int)strtol(p, &p, 16);
                    if (f == frame) mem[keys + k] = up ? 0 : 0xff;
                    if (*p == ',') p++;
                }
            }
            if (frame % FPS == 0) {
                static unsigned int last_drawn;
                unsigned int drawn = getenv("BT_DRAWN") ? rd16(BASE + (unsigned int)strtoul(getenv("BT_DRAWN"), NULL, 16)) : 0;
                printf("second %d: vblank handler %.0f%%, display %.0f%% of the CPU, arcade frames %u, frames drawn %u, PC %06x\n",
                       frame / FPS, 100.0 * in_lev3 / ((double)FPS * FRAME), 100.0 * disp_cycles / ((double)FPS * FRAME), z80_frames,
                       (drawn - last_drawn) & 0xffff, m68k_get_reg(NULL, M68K_REG_PC) - BASE);
                disp_cycles = 0;
                last_drawn = drawn;
                printf("  idle %.0f%%", 100.0 * idle_cycles / ((double)FPS * FRAME));
                if (rt_start) printf(", routine %.0f%% (%llu calls)", 100.0 * rt_cycles / ((double)FPS * FRAME), rt_calls);
                printf("\n");
                idle_cycles = rt_cycles = rt_calls = 0;
                if (getenv("BT_OVL")) {
                    static unsigned int last_ovl;
                    unsigned int o = rd16(BASE + (unsigned int)strtoul(getenv("BT_OVL"), NULL, 16));
                    if (o != last_ovl) printf("  colour slots borrowed: %u\n", (o - last_ovl) & 0xffff);
                    last_ovl = o;
                }
                in_lev3 = 0;
                z80_frames = 0;
                if (dumpi < argc && atoi(argv[dumpi]) == frame / FPS) {
                    dump_text();
                    check_text();
                    char dn[256];
                    snprintf(dn, sizeof dn, "%s_%d.bin", getenv("BT_DUMP") ? getenv("BT_DUMP") : "build/amiga_mem", frame / FPS);
                    FILE *df = fopen(dn, "wb");   /* for tools/harness/render_frame.py */
                    fwrite(mem, 1, BASE > 0x10000 ? MEMSIZE : 0x400000, df);
                    fclose(df);
                    dumpi++;
                }
            }
        }
    }
    for (int i = 0; i + 1 < nprobes; i++)
        if (probe_n[i]) printf("probe %d -> %d: %llu cycles on average\n", i, i + 1, probe_sum[i] / probe_n[i]);
    return 0;
}
