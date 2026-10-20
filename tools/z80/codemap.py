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
NO_RETURN = {0x0135}   # scheduler: end current task


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
        self.bank_ctx = {}         # (bank, addr) -> bank mapped there (fixed code), False if mixed
        self.tables = {}           # (bank, table address) -> entry points read from it

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
                    if key[0] is None and self.bank_ctx.get(key) not in (bank, False):
                        # fixed code reached with another bank mapped: re-trace once as mixed
                        if self.bank_ctx[key] is not None and bank is not None:
                            self.bank_ctx[key] = False
                    break
                ins = decode(Space(self.rom, bank), pc)
                self.insns[key] = ins
                self.bank_ctx[key] = bank
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
                    if k == "call" and ins.cond is None and tgt in NO_RETURN:
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
    cm.seeds = set()
    if dynamic_path:
        # only seed from recorded addresses the static trace hasn't explained:
        # those are the targets of computed jumps and task entry points
        for b, a in load_dynamic(dynamic_path):
            if (b, a) in cm.insns:
                continue
            cm.seeds.add((b, a))
            cm.entries.add((b, a))
            cm.add(b, a)
    # the static passes, until none of them finds anything new
    while True:
        n = len(cm.insns)
        static_tables(cm)
        data_pointers(cm)
        gap_routines(cm)
        bank_entry_tables(cm)
        object_handlers(cm)
        multiway_returns(cm)
        if len(cm.insns) == n:
            break
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


def stack_report(cm):
    """Routines that read or replace their own return address.

    Walks each call target without following calls, tracking how many bytes
    the routine has pushed. Returns {(bank, addr): [events]}.
    """
    found = {}
    for entry in sorted(cm.calls, key=lambda k: (-1 if k[0] is None else k[0], k[1])):
        seen = {}
        work = [(entry, 0)]
        while work:
            key, depth = work.pop()
            if key in seen or key not in cm.insns:
                continue
            seen[key] = depth
            ins = cm.insns[key]
            t = ins.text.split(" ;")[0]
            ev = None
            if t.startswith("push "):
                depth += 2
            elif t.startswith("pop "):
                if depth == 0:
                    ev = "pops return address into %s" % t[4:]
                depth = max(depth - 2, 0)
            elif t.startswith("ex (sp)") and depth == 0:
                ev = "swaps return address (%s)" % t
            elif t.startswith(("ld sp", "inc sp", "dec sp", "add hl,sp")):
                ev = "stack pointer arithmetic (%s)" % t
            elif ins.kind == "ret" and depth != 0:
                ev = "returns with %d bytes pushed (jump to pushed value)" % depth
            if ev:
                found.setdefault(entry, []).append("%04x: %s" % (key[1], ev))
            if ins.kind == "ret" and ins.cond is None or ins.kind in ("reti", "jpind"):
                continue
            if ins.kind in ("jp", "jr") and ins.target is not None:
                work.append((loc(key[0], ins.target), depth))
                if ins.cond is None and ins.text.split()[0] != "djnz":
                    continue
            if ins.kind == "call" and ins.cond is None and ins.target in NO_RETURN:
                continue
            work.append((loc(key[0], key[1] + ins.length), depth))
    return found


def stack_depths(cm):
    """Stack depth (bytes pushed since routine entry) of every instruction.

    Returns (depths, multiway, conflicts):
      depths    {(bank, addr): set of depths}  (negative = popping the caller's frame)
      multiway  {routine: set of k}  routines that can return to return-address + k
      conflicts [text]
    A pop at depth 0 consumes the return address.
    """
    depths = {}
    multiway = {}
    conflicts = []
    for entry in sorted(cm.calls, key=lambda k: (-1 if k[0] is None else k[0], k[1])):
        seen = set()
        work = [(entry, 0)]
        while work:
            key, depth = work.pop()
            if (key, depth) in seen or key not in cm.insns:
                continue
            seen.add((key, depth))
            depths.setdefault(key, set()).add(depth)
            ins = cm.insns[key]
            t = ins.text.split(" ;")[0]
            if t.startswith("pop ") and depth == 0 and t == "pop hl":
                # pop hl / inc hl * k / jp (hl) ?
                k, p = 0, key[1] + ins.length
                nxt = cm.insns.get(loc(key[0], p))
                while nxt is not None and nxt.text == "inc hl":
                    k += 1
                    p += nxt.length
                    nxt = cm.insns.get(loc(key[0], p))
                if nxt is not None and nxt.text == "jp (hl)":
                    multiway.setdefault(entry, set()).add(k)
                    continue
            if t.startswith("push "):
                depth += 2
            elif t.startswith("pop "):
                depth -= 2
            if ins.kind == "ret" and ins.cond is None or ins.kind in ("reti", "jpind"):
                continue
            if ins.kind in ("jp", "jr") and ins.target is not None:
                work.append((loc(key[0], ins.target), depth))
                if ins.cond is None and t.split()[0] != "djnz":
                    continue
            if ins.kind == "call" and ins.cond is None and ins.target in NO_RETURN:
                continue
            work.append((loc(key[0], key[1] + ins.length), depth))
    for key, ds in depths.items():
        t = cm.insns[key].text
        if t.startswith("pop ") and 0 in ds and len(ds) > 1:
            conflicts.append("%04x %s: reached at depths %s" % (key[1], t, sorted(ds)))
    return depths, multiway, conflicts


DISPATCH = 0x0408   # add a,a / ld e,a / ld d,0 / add hl,de / ld e,(hl) / inc hl / ld d,(hl) / ex de,hl / jp (hl)


def multiway_returns(cm):
    """Multi-way returns: code at return address + k is reachable too."""
    while True:
        _, multiway, _ = stack_depths(cm)
        new = []
        for key, ins in list(cm.insns.items()):
            if ins.kind == "call" and loc(cm.bank_ctx.get(key) if key[0] is None else key[0],
                                           ins.target) in multiway:
                tb = cm.bank_ctx.get(key) if key[0] is None else key[0]
                for k in multiway[loc(tb, ins.target)]:
                    r = loc(key[0], key[1] + ins.length + k)
                    if r not in cm.insns:
                        new.append(r)
        if not new:
            break
        for b, a in new:
            cm.entries.add((b, a))
            cm.add(b, a)


def static_tables(cm):
    """Jump tables found from the code: `ld hl,TABLE` followed within the same
    block by a jump/call to the dispatcher at $0408, or by the inline lookup
    `ld e,(hl) / inc hl / ld d,(hl) / ex de,hl / jp (hl)`. The table is read
    until an entry is not a code pointer, the table runs into code, or 128
    entries. Repeats while new code turns up."""
    while True:
        found = []
        for key, ins in list(cm.insns.items()):
            if not ins.text.startswith("ld hl,$") or len(ins.text) != 11:
                continue
            table = int(ins.text[-4:], 16)
            bank = key[0] if key[0] is not None else cm.bank_ctx.get(key) or None
            tkey = loc(bank, table)
            if tkey in cm.tables or not (table < 0x8000 or (0x8000 <= table < 0xC000 and bank is not None)):
                continue
            pc, seq = key[1] + ins.length, []
            for _ in range(10):
                n = cm.insns.get(loc(key[0], pc))
                if n is None:
                    break
                seq.append(n.text)
                if n.kind in ("jp", "call") and n.target == DISPATCH or n.kind == "jpind":
                    break
                if n.kind in ("jp", "jr", "ret", "reti", "call", "rst") and n.cond is None:
                    break
                pc += n.length
            if seq and seq[0] == "push hl":
                continue                                    # a hand-pushed return address
            # HL must reach the lookup unchanged except for an added index
            end = len(seq)
            for i, t in enumerate(seq):
                if t == "ld e,(hl)" or t.startswith(("jp $%04x" % DISPATCH, "call $%04x" % DISPATCH)):
                    end = i
                    break
            if any(t.startswith(("ld hl,", "ld h,", "ld l,", "pop hl", "ex de,hl", "ex (sp),hl",
                                 "inc hl", "dec hl", "inc l", "dec l", "inc h", "dec h"))
                   for t in seq[:end]):
                continue
            text = " / ".join(seq)
            dispatch = ("$%04x" % DISPATCH) in text and seq and seq[-1].startswith(("jp $", "call $"))
            inline = "ld e,(hl) / inc hl / ld d,(hl) / ex de,hl / jp (hl)" in text
            if dispatch or inline:
                found.append((tkey, bank))
        if not found:
            return
        code = cm.code_bytes()
        for (tb, ta), bank in found:
            if tb is None:
                bank = None             # a table in the fixed ROM points into the fixed ROM
            sp = Space(cm.rom, bank)
            entries = []
            for i in range(128):
                a = ta + 2 * i
                if i and (loc(tb, a) in cm.insns or any(k[1] == a for k in entries)):
                    break                                   # the table ran into code / its own target
                w = sp[a] | sp[a + 1] << 8
                if w in (0, 0xFFFF) or not (w < 0x8000 or (bank is not None and w < 0xC000)):
                    break
                if entries and (w < 0x8000) != (entries[0][1] < 0x8000):
                    break                                   # left the region of the first entry
                k = loc(bank, w)
                if k not in cm.insns and k in code:
                    break                                   # into the middle of an instruction
                if k not in cm.insns and not _looks_like_code(cm, k[0], w):
                    break
                entries.append(k)
            cm.tables[(tb, ta)] = entries
            for k in entries:
                cm.entries.add(k)
                cm.add(*k)


def data_pointers(cm):
    """Code addresses kept in data (object scripts and the like): a word
    outside the known code that points at the address right after a known
    unconditional jp / jr / ret or a known jump table, where the code map has
    nothing yet (code that can't be fallen into, so only reached through a
    pointer), and that decodes as code. Banked data is searched for pointers into its own bank, the fixed
    ROM for pointers into the fixed ROM. Repeats while new code turns up."""
    banks = [None] + list(range(16))
    while True:
        code = cm.code_bytes()
        ends = set()                # (bank, addr) right after an unconditional transfer
        for (b, a), ins in cm.insns.items():
            if ins.cond is None and ins.kind in ("jp", "jr", "ret", "reti"):
                ends.add(loc(b, a + ins.length))
        for (tb, ta), entries in cm.tables.items():    # ... or after a jump table
            ends.add((tb, ta + 2 * len(entries)))
        found = set()
        for bank in banks:
            sp = Space(cm.rom, bank)
            lo, hi = (0, 0x8000) if bank is None else (0x8000, 0xC000)
            for a in range(lo, hi - 1):
                if loc(bank, a) in code or loc(bank, a + 1) in code:
                    continue
                w = sp[a] | sp[a + 1] << 8
                if not lo <= w < hi:
                    continue
                k = loc(bank, w)
                if (k in ends and k not in cm.insns and _looks_like_code(cm, bank, w, strict=True)
                        and _closure_ok(cm, bank, w)):
                    found.add(k)
        if not found:
            return
        for k in sorted(found, key=lambda k: (k[0] if k[0] is not None else -1, k[1])):
            cm.entries.add(k)
            cm.add(*k)


HANDLER_PREFIX = bytes([0x2A, 0x27, 0xE9, 0x7E, 0xA7, 0xC0])   # ld hl,($e927) / ld a,(hl) / and a / ret nz


def object_handlers(cm):
    """Object handlers start with HANDLER_PREFIX and are only reached through
    level data and object scripts (entered at the start, or at the
    instruction after the prefix): take every such routine outside the known
    code that reads as code."""
    code = cm.code_bytes()
    for bank in [None] + list(range(16)):
        sp = Space(cm.rom, bank)
        lo, hi = (0, 0x8000) if bank is None else (0x8000, 0xC000)
        data = bytes(sp[a] for a in range(lo, hi))
        i = data.find(HANDLER_PREFIX)
        while i >= 0:
            a = lo + i
            k = loc(bank, a)
            if k not in code and _closure_ok(cm, bank, a):
                for e in (k, loc(bank, a + len(HANDLER_PREFIX))):
                    cm.entries.add(e)
                    cm.add(*e)
                code = cm.code_bytes()
            i = data.find(HANDLER_PREFIX, i + 1)


def bank_entry_tables(cm):
    """Tables of entry points in other banks, in the fixed ROM: runs of at
    least two 4-byte records (bank, 0, address in $8000-$BFFF) outside the
    known code whose targets read as code in that bank (e.g. $72EB, item
    handlers reached through a bank-switching dispatcher)."""
    code = cm.code_bytes()
    rom = cm.rom

    def rec(a):
        b, z, w = rom[a], rom[a + 1], rom[a + 2] | rom[a + 3] << 8
        if b < 16 and z == 0 and 0x8000 <= w < 0xC000 and not any((None, a + i) in code for i in range(4)):
            if (b, w) in cm.insns or (_looks_like_code(cm, b, w) and _closure_ok(cm, b, w)):
                return (b, w)
        return None

    found, a = [], 0
    while a < 0x8000 - 4:
        if rec(a) and rec(a + 4):
            while rec(a):
                found.append(rec(a))
                a += 4
        else:
            a += 1
    for k in found:
        if k not in cm.insns:
            cm.entries.add(k)
            cm.add(*k)


def gap_routines(cm):
    """Routines laid out one after another but only reached through computed
    addresses (e.g. object behaviours in a bank): right after a known
    unconditional jp / jr / ret where nothing is known yet, take the bytes as
    code if they read as a complete small routine - plausible instructions
    (_looks_like_code strict) up to an unconditional ret or jp within 24
    instructions, none of them already known, branches inside the ROM area.
    Repeats while new code turns up."""
    while True:
        found = []
        loaded = set()          # addresses some code loads into HL: tables, not code
        for (b, a), ins in cm.insns.items():
            if ins.text.startswith("ld hl,$") and len(ins.text) == 11:
                loaded.add(int(ins.text[-4:], 16))
        for (b, a), ins in list(cm.insns.items()):
            if ins.cond is not None or ins.kind not in ("jp", "jr", "ret", "reti"):
                continue
            k = loc(b, a + ins.length)
            if k in cm.insns or (k[0] is None and k[1] >= 0x8000) or k[1] >= 0xC000:
                continue
            if k[1] in loaded or k in cm.tables:
                continue
            if _small_routine(cm, k[0], k[1]) and _closure_ok(cm, k[0], k[1]):
                found.append(k)
        if not found:
            return
        for k in found:
            cm.entries.add(k)
            cm.add(*k)


def _small_routine(cm, bank, addr):
    if not _looks_like_code(cm, bank, addr, strict=True):
        return False
    sp = Space(cm.rom, bank)
    hi = 0x8000 if bank is None else 0xC000
    pc = addr
    for _ in range(24):
        if loc(bank, pc) in cm.insns or pc >= hi:
            return False
        ins = decode(sp, pc)
        t = ins.text
        if ("undefined" in t or "prefix" in t or t in ("nop", "halt", "rst $38")
                or (t.startswith("ld ") and len(t) == 6 and t[3] == t[5])):
            return False
        if ins.kind in ("jp", "jr", "call") and ins.target is not None and not (
                ins.target < 0x8000 or (bank is not None and ins.target < 0xC000)):
            return False
        if ins.cond is None and ins.kind in ("ret", "jp", "jr", "jpind", "reti"):
            return True
        pc += ins.length
    return False


def _closure_ok(cm, bank, addr, limit=400):
    """Everything newly reachable from addr decodes cleanly and never jumps
    into RAM: what a real routine looks like, and junk usually doesn't."""
    sp = Space(cm.rom, bank)
    hi = 0x8000 if bank is None else 0xC000
    work, seen = [addr], set()
    while work:
        pc = work.pop()
        while True:
            k = loc(bank, pc)
            if k in cm.insns or pc in seen:
                break
            if pc >= 0xC000 or (bank is None and pc >= 0x8000):
                return False
            seen.add(pc)
            if len(seen) > limit:
                return False
            ins = decode(sp, pc)
            if "undefined" in ins.text or "prefix" in ins.text or ins.kind == "halt":
                return False
            if ins.text in ("inc sp", "dec sp") or ins.text.startswith(("add hl,sp", "ld sp,(")):
                return False
            if ins.kind in ("jp", "jr", "call", "rst") and ins.target is not None:
                if ins.target >= 0xC000 or (bank is None and ins.target >= 0x8000):
                    return False
                if not (ins.kind == "call" and ins.target == BANK_SETTER):
                    work.append(ins.target)
            if ins.cond is None and ins.kind in ("jp", "jr", "ret", "reti", "jpind"):
                break
            if ins.kind == "call" and ins.cond is None and (ins.target in NO_RETURN or ins.target == BANK_SETTER):
                break
            pc += ins.length
    return True


def _looks_like_code(cm, bank, addr, strict=False):
    """The first few instructions decode without undefined opcodes or prefixes
    (strict: nor nop, halt, rst $38, ld r,r - typical of data)."""
    sp = Space(cm.rom, bank)
    pc = addr
    for _ in range(6):
        ins = decode(sp, pc)
        if "undefined" in ins.text or "ignored prefix" in ins.text or "bad prefix" in ins.text:
            return False
        if strict:
            t = ins.text
            if t in ("nop", "halt", "rst $38") or (
                    t.startswith("ld ") and len(t) == 6 and t[3] == t[5]):
                return False
        if ins.kind in ("ret", "jp", "jr", "jpind", "reti") and ins.cond is None:
            return True
        pc += ins.length
    return True
