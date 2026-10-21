/* Black Tiger AGA - run the sound translation's test build (src/sound_test.s)
 * on Musashi and print its YM2203 writes: "W time chip reg value" (time in
 * units of 72 YM clocks).
 * usage: sound_sim sound_test.bin > writes.txt
 */
#include <stdio.h>
#include <stdlib.h>
#include "m68k.h"

#define MEMSIZE 0x01000000
#define BASE 0x10000
static unsigned char mem[MEMSIZE];
static unsigned int now;
static unsigned int rd16(unsigned int a);
/* the last instructions executed (SND_HIST=lo,hi: of the translation's code), for a stuck run */
static unsigned int hist[4096], hist_n, hist_lo, hist_hi;
/* SND_WATCH=offset: when that code is entered, watch its return address on the stack */
static unsigned int watch_pc, watch_sp, cur_pc;
void snd_hook(unsigned int pc)
{
    cur_pc = pc;
    static unsigned int tr[32], ntr = (unsigned int)-1;      /* SND_TRACE=a,b,c: print when entered */
    if (ntr == (unsigned int)-1) {
        ntr = 0;
        char *p = getenv("SND_TRACE");
        while (p && *p && ntr < 32) { tr[ntr++] = (unsigned int)strtoul(p, &p, 16); if (*p == ',') p++; }
    }
    if (now >= 1307000)
        for (unsigned int i = 0; i < ntr; i++)
            if (pc == tr[i] + BASE) printf("T %06x sp %06x time %u\n", tr[i], m68k_get_reg(NULL, M68K_REG_SP), now);
    if (watch_pc && pc == watch_pc + BASE) watch_sp = m68k_get_reg(NULL, M68K_REG_SP);
    pc -= BASE;
    if (hist_hi && rd16((pc + BASE) & (MEMSIZE - 2)) == 0x0000) {     /* ori.b #0,d0: data run as code */
        printf("DATA RUN at pc %06x, time %u\n", pc, now);
        for (unsigned int i = hist_n > 4096 ? hist_n - 4096 : 0; i < hist_n; i++)
            printf("H %06x\n", hist[i & 4095] & 0xffffff);
        exit(1);
    }
    static int out;                                 /* (the last ones in the code, then 64 outside) */
    if (pc >= hist_lo && pc < hist_hi) { hist[hist_n++ & 4095] = pc; out = 0; }
    else if (hist_hi && out < 64) { hist[hist_n++ & 4095] = pc | 0x80000000u; out++; }
}
static int done;

static unsigned int rd16(unsigned int a) { return mem[a] << 8 | mem[a + 1]; }
unsigned int m68k_read_memory_8(unsigned int a) { return mem[a & (MEMSIZE - 1)]; }
unsigned int m68k_read_memory_16(unsigned int a) { return rd16(a & (MEMSIZE - 1)); }
unsigned int m68k_read_memory_32(unsigned int a) { a &= MEMSIZE - 1; return rd16(a) << 16 | rd16(a + 2); }
unsigned int m68k_read_immediate_16(unsigned int a) { return m68k_read_memory_16(a); }
unsigned int m68k_read_immediate_32(unsigned int a) { return m68k_read_memory_32(a); }
unsigned int m68k_read_pcrelative_8(unsigned int a) { return m68k_read_memory_8(a); }
unsigned int m68k_read_pcrelative_16(unsigned int a) { return m68k_read_memory_16(a); }
unsigned int m68k_read_pcrelative_32(unsigned int a) { return m68k_read_memory_32(a); }
unsigned int m68k_read_disassembler_16(unsigned int a) { return m68k_read_memory_16(a); }
unsigned int m68k_read_disassembler_32(unsigned int a) { return m68k_read_memory_32(a); }
static void watch(unsigned int a, int n)
{
    if (watch_sp && a < watch_sp + 4 && a + n > watch_sp)
        printf("WATCH: return address at %06x written by pc %06x (time %u)\n", watch_sp, cur_pc - BASE, now);
}
void m68k_write_memory_8(unsigned int a, unsigned int v) { watch(a, 1); mem[a & (MEMSIZE - 1)] = v; }
void m68k_write_memory_16(unsigned int a, unsigned int v)
{
    a &= MEMSIZE - 1;
    watch(a, 2);
    mem[a] = v >> 8;
    mem[a + 1] = v;
}
void m68k_write_memory_32(unsigned int a, unsigned int v)
{
    a &= MEMSIZE - 1;
    if (a == 0xf00000) { printf("W %u %u %02x %02x\n", now, (v >> 16) & 1, (v >> 8) & 0xff, v & 0xff); return; }
    if (a == 0xf00004) { now = v; return; }
    if (a == 0xf0000c) { if (getenv("SND_DEBUG")) printf("EV %06x at %u\n", v, now); return; }
    if (a == 0xf00008) {
        if ((v >> 16) == 0xfd) printf("BAD JUMP %06x\n", v);
        else printf("END %u (pc %06x, now %u)\n", v, m68k_get_reg(NULL, M68K_REG_PPC) - BASE, now);
        done = 1;
        return;
    }
    m68k_write_memory_16(a, v >> 16);
    m68k_write_memory_16(a + 2, v & 0xffff);
}

int main(int argc, char **argv)
{
    FILE *f = fopen(argv[1], "rb");
    if (!f) { perror(argv[1]); return 1; }
    fread(mem + BASE, 1, MEMSIZE - BASE, f);
    fclose(f);
    mem[0] = 0; mem[1] = 0x0f; mem[2] = 0; mem[3] = 0;      /* SSP */
    mem[4] = 0; mem[5] = BASE >> 16; mem[6] = 0; mem[7] = 0;
    if (getenv("SND_WATCH")) watch_pc = (unsigned int)strtoul(getenv("SND_WATCH"), NULL, 16);
    if (getenv("SND_HIST")) sscanf(getenv("SND_HIST"), "%x,%x", &hist_lo, &hist_hi);
    m68k_init();
    m68k_set_cpu_type(M68K_CPU_TYPE_68020);
    m68k_pulse_reset();
    long long budget = 1500000000LL;           /* (a stuck run: say where) */
    while (!done) {
        budget -= m68k_execute(100000);
        if (budget < 0) {
            printf("STUCK at pc %06x, time %u\n", m68k_get_reg(NULL, M68K_REG_PC) - BASE, now);
            for (unsigned int i = hist_n > 4096 ? hist_n - 4096 : 0; i < hist_n; i++) printf("H %06x%s\n", hist[i & 4095] & 0xffffff, hist[i & 4095] >> 31 ? " (outside)" : "");
            return 1;
        }
    }
    return 0;
}
