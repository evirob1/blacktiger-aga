"""Find the code in the Black Tiger main CPU ROMs.

Static recursive descent from the entry points, tracking which ROM bank is
mapped at $8000-$BFFF, plus extra entry points and indirect jump targets
recorded from MAME (tools/mame/codemap.lua -> analysis/dynamic.txt).

Code locations are (bank, addr): bank is None for the fixed ROM ($0000-$7FFF).
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from z80.decode import decode  # noqa: E402

BANK_SETTER = 0x034B   # ld ($e0e3),a / out ($01),a / ret
ENTRY_POINTS = [0x0000, 0x0038, 0x0066]


class Space:
    """64K view of the main CPU with a given bank mapped at $8000."""

    def __init__(self, rom, bank):
        self.rom, self.bank = rom, bank

    def __getitem__(self, a):
        a &= 0xFFFF
        if a < 0x8000:
            return self.rom[a]
        if a < 0xC000 and self.bank is not None:
            return self.rom[0x10000 + self.bank * 0x4000 + a - 0x8000]
        return 0xFF


def loc(bank, addr):
    return (bank if 0x8000 <= addr < 0xC000 else None, addr)


class CodeMap:
    def __init__(self, rom):
        self.rom = rom
        self.insns = {}            # (bank, addr) -> Insn
        self.entries = set()       # (bank, addr) labels: jump/call targets
        self.calls = set()
        self.indirect = set()      # (bank, addr) of jp (hl)/(ix)/(iy)
        self.unknown_bank = set()  # addr in $8000-$BFFF reached with unknown bank
        self.ram_targets = set()

    def add(self, bank, addr):
        """Trace from addr with `bank` mapped (None = unknown)."""
        work = [(bank, addr, None)]
        while work:
            bank, pc, a_val = work.pop()
            while True:
                if pc >= 0xC000:
                    self.ram_targets.add(pc)
                    break
                if 0x8000 <= pc < 0xC000 and bank is None:
                    self.unknown_bank.add(pc)
                    break
                key = loc(bank, pc)
                if key in self.insns:
                    break
                ins = decode(Space(self.rom, bank), pc)
                self.insns[key] = ins
                t = ins.text
                nxt = pc + ins.length
                # very small constant tracking: the value of A, for bank switches
                if t.startswith("ld a,$") and len(t) == 8:
                    a_val = int(t[6:], 16)
                elif t == "xor a":
                    a_val = 0
                elif t.startswith("ld a,") or t.split(" ")[0] in (
                        "add", "adc", "sub", "sbc", "and", "xor", "or", "inc", "dec", "pop",
                        "in", "rla", "rra", "rlca", "rrca", "cpl", "neg", "ex", "exx", "daa"):
                    if " a" in t or t.startswith(("pop af", "ex af", "exx", "in a", "rla", "rra",
                                                  "rlca", "rrca", "cpl", "neg", "daa")):
                        a_val = None
                if t == "out ($01),a":
                    bank = a_val
                k = ins.kind
                if k in ("jp", "jr", "call", "rst"):
                    tgt = ins.target
                    if k == "call" and tgt == BANK_SETTER:
                        bank = a_val
                    else:
                        self.entries.add(loc(bank, tgt))
                        if k in ("call", "rst"):
                            self.calls.add(loc(bank, tgt))
                        work.append((bank, tgt, a_val if k in ("jp", "jr") else None))
                    if k in ("jp", "jr") and ins.cond is None:
                        break
                    if k in ("call", "rst"):
                        a_val = None
                elif k == "ret" and ins.cond is None:
                    break
                elif k == "reti":
                    break
                elif k == "jpind":
                    self.indirect.add(key)
                    break
                elif k == "halt":
                    pass
                pc = nxt

    def code_bytes(self):
        """(bank, addr) of every byte covered by an instruction."""
        out = set()
        for (b, a), ins in self.insns.items():
            for i in range(ins.length):
                out.add(loc(b, a + i))
        return out


def load_dynamic(path):
    """Lines: 'E bank addr' (entry seen executing), 'J bank site target' (indirect jump)."""
    entries = []
    if not os.path.exists(path):
        return entries
    for line in open(path):
        f = line.split()
        if not f:
            continue
        if f[0] == "E":
            b, a = int(f[1], 16), int(f[2], 16)
            entries.append((b if 0x8000 <= a < 0xC000 else None, a))
        elif f[0] == "J":
            b, t = int(f[1], 16), int(f[3], 16)
            entries.append((b if 0x8000 <= t < 0xC000 else None, t))
    return entries


def build(rom, dynamic_path=None):
    cm = CodeMap(rom)
    for e in ENTRY_POINTS:
        cm.entries.add((None, e))
        cm.add(None, e)
    if dynamic_path:
        for b, a in load_dynamic(dynamic_path):
            cm.entries.add((b, a))
            cm.add(b, a)
    return cm


def main():
    sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    import bt_rom
    rom = bt_rom.load_roms(sys.argv[1])["maincpu"]
    cm = build(rom, sys.argv[2] if len(sys.argv) > 2 else None)
    fixed = sum(1 for (b, a) in cm.insns if b is None)
    per_bank = {}
    for (b, a) in cm.insns:
        if b is not None:
            per_bank[b] = per_bank.get(b, 0) + 1
    cb = cm.code_bytes()
    print("instructions: fixed %d, banked %s" % (fixed, dict(sorted(per_bank.items()))))
    print("code bytes in fixed ROM: %d of 32768" % sum(1 for b, a in cb if b is None))
    print("indirect jump sites: %d   unknown-bank entries: %d   RAM targets: %s" %
          (len(cm.indirect), len(cm.unknown_bank), sorted(hex(x) for x in cm.ram_targets)))
    print("unknown-bank entries:", " ".join("%04x" % a for a in sorted(cm.unknown_bank)))
    print("indirect sites:", " ".join(("%x:" % b if b is not None else "") + "%04x" % a
                                      for b, a in sorted(cm.indirect, key=lambda k: (k[0] or -1, k[1]))))


if __name__ == "__main__":
    main()
