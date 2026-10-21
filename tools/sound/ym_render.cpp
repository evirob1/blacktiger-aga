// Render YM2203 register writes with ymfm (the YM2203 emulation MAME uses):
// the arcade's two chips, from a log of writes, to raw 32-bit float samples
// at the chips' rate (clock / 24): FM and SSG separately, both chips summed
// (tools/sound/effects.py mixes them as the arcade does).
//
// input: lines "time_seconds chip register value" (hex register / value)
// usage: ym_render log.txt seconds fm.f32 ssg.f32
#include <cstdio>
#include <cstdlib>
#include <vector>
#include "ymfm_opn.h"

static const uint32_t CLOCK = 3579545;

struct Write { double t; int chip, reg, val; };

int main(int argc, char **argv)
{
    if (argc < 5) { fprintf(stderr, "usage: ym_render log.txt seconds fm.f32 ssg.f32\n"); return 1; }
    std::vector<Write> log;
    FILE *f = fopen(argv[1], "r");
    if (!f) { perror(argv[1]); return 1; }
    Write w;
    while (fscanf(f, "%lf %d %x %x", &w.t, &w.chip, &w.reg, &w.val) == 4) log.push_back(w);
    fclose(f);
    double seconds = atof(argv[2]);

    ymfm::ymfm_interface intf[2];
    ymfm::ym2203 chip0(intf[0]), chip1(intf[1]);
    ymfm::ym2203 *chips[2] = { &chip0, &chip1 };
    for (auto *c : chips) {
        c->set_fidelity(ymfm::OPN_FIDELITY_MIN);
        c->reset();
    }
    uint32_t rate = chip0.sample_rate(CLOCK);
    FILE *ffm = fopen(argv[3], "wb"), *fssg = fopen(argv[4], "wb");
    if (!ffm || !fssg) { perror("output"); return 1; }
    size_t next = 0;
    uint64_t n = (uint64_t)(seconds * rate);
    for (uint64_t i = 0; i < n; i++) {
        double t = (double)i / rate;
        while (next < log.size() && log[next].t <= t) {
            const Write &e = log[next++];
            chips[e.chip & 1]->write(0, (uint8_t)e.reg);
            chips[e.chip & 1]->write(1, (uint8_t)e.val);
        }
        float fm = 0, ssg = 0;
        for (auto *c : chips) {
            ymfm::ym2203::output_data out;
            c->generate(&out);
            fm += out.data[0] / 32768.0f;
            ssg += (out.data[1] + out.data[2] + out.data[3]) / 32768.0f;
        }
        fwrite(&fm, 4, 1, ffm);
        fwrite(&ssg, 4, 1, fssg);
    }
    fclose(ffm);
    fclose(fssg);
    fprintf(stderr, "%u Hz, %llu samples\n", rate, (unsigned long long)n);
    return 0;
}
