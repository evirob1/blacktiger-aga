"""Find the code in the Black Tiger main CPU ROMs.

Static recursive descent from the entry points, tracking which ROM bank is
mapped at $8000-$BFFF, plus extra entry points and indirect jump targets
recorded from MAME (tools/mame/codemap.lua -> analysis/dynamic.txt).

Code locations are (bank, addr): bank is None for the fixed ROM ($0000-$7FFF).
"""
import os
import re
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
        self.rst_targets = {}      # sound CPU: rst $30 site -> its jump table's entries

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
                    if k in ("call", "rst") and ins.cond is None and tgt in NO_RETURN:
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


SOUND_ENTRY_POINTS = [0x0000, 0x0038]
SOUND_RST_TABLE = 0x0030   # rst $30: jump through the table of words after it
SOUND_CODE_END = 0x0DC1    # the command table: data from here on


def rst_tables(cm):
    """Sound CPU: the words after each rst $30 are a jump table (entry A),
    up to where the first of its targets begins (0: an unused entry)."""
    rom = cm.rom
    for (b, a), ins in list(cm.insns.items()):
        if ins.kind != "rst" or ins.target != SOUND_RST_TABLE:
            continue
        p, end = a + 1, SOUND_CODE_END
        targets = cm.rst_targets.setdefault((b, a), [])
        while p + 2 <= end:
            w = rom[p] | rom[p + 1] << 8
            if w == 0:                  # (an unused entry: $07C7's has two)
                p += 2
                continue
            if not 0x0100 <= w < SOUND_CODE_END:
                break
            end = min(end, w)
            if w not in targets:
                targets.append(w)
            k = loc(None, w)
            if k not in cm.insns:
                cm.entries.add(k)
                cm.add(None, w)
            p += 2


def build(rom, dynamic_path=None, sound=False):
    """sound: the sound CPU's program (32K, no banks, no main-board passes)."""
    global NO_RETURN, BANK_SETTER
    if sound:                       # (main ROM addresses: nothing special here)
        NO_RETURN, BANK_SETTER = {SOUND_RST_TABLE}, None
    cm = CodeMap(rom)
    for e in SOUND_ENTRY_POINTS if sound else ENTRY_POINTS:
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
        if sound:
            rst_tables(cm)
            multiway_returns(cm)
            if len(cm.insns) == n:
                break
            continue
        static_tables(cm)
        data_pointers(cm)
        gap_routines(cm)
        bank_entry_tables(cm)
        object_handlers(cm)
        level_objects(cm)
        object_scripts(cm)
        task_entries(cm)
        multiway_returns(cm)
        if len(cm.insns) == n:
            break
    return cm


TASK_CREATE = 0x00F6


def task_entries(cm):
    """Tasks the scheduler starts: ld bc,entry / call $00F6, anywhere in the
    ROM (the code that does it may itself be reached only by computed jumps
    nothing traced). An entry sets its stack first (ld sp,nn), which tells
    them from data that happens to look the same; an entry at $8000-$BFFF is
    in the bank of the code starting it."""
    rom = cm.rom
    for m in re.finditer(rb"\x01(..)\xcd" + bytes([TASK_CREATE & 0xFF, TASK_CREATE >> 8]), rom, re.S):
        at, t = m.start(), m.group(1)[0] | m.group(1)[1] << 8
        if 0x8000 <= at < 0x10000:
            continue
        bank = None if at < 0x8000 else (at - 0x10000) // 0x4000
        if t < 0x8000:
            k = loc(None, t)
        elif t < 0xC000 and bank is not None:
            k = loc(bank, t)
        else:
            continue
        if Space(rom, k[0])[t] == 0x31 and k not in cm.insns:
            cm.entries.add(k)
            cm.add(*k)


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
            if key in cm.rst_targets:
                # a jump table (sound CPU's rst $30): to each entry, at this
                # depth (the rst's return address is the table, popped again)
                for w in cm.rst_targets[key]:
                    work.append((loc(None, w), depth))
                continue
            work.append((loc(key[0], key[1] + ins.length), depth))
    for key, ds in depths.items():
        t = cm.insns[key].text
        if t.startswith("pop ") and 0 in ds and len(ds) > 1:
            conflicts.append("%04x %s: reached at depths %s" % (key[1], t, sorted(ds)))
    return depths, multiway, conflicts


def pop_kinds(cm, entries):
    """What each pop takes off the stack: "c" (a code address: a return
    address, 4 bytes on the 68k, or one pushed by hand with ld rr,code / push
    rr) or "d" (a 16-bit value pushed with push). Follows the program from its
    entry points through calls (each pushes a return address, and the callee
    starts with the caller's stack), so a pop that escapes to a caller's frame
    sees what is really there. Returns {(bank, addr) of a pop: set of kinds}
    ("?": below the entry's stack). For the sound CPU's small program."""
    kinds = {}
    seen = set()
    work = [(loc(None, e), ()) for e in entries]
    while work:
        key, stack = work.pop()
        if (key, stack) in seen or key not in cm.insns or len(stack) > 24:
            continue
        seen.add((key, stack))
        ins = cm.insns[key]
        t = ins.text.split(" ;")[0]
        nxt = loc(key[0], key[1] + ins.length)
        if t.startswith("push "):
            prev = cm.insns.get(loc(key[0], key[1] - 3))
            code = (prev is not None and prev.pc + prev.length == key[1] and
                    re.match(r"ld %s,\$[0-9a-f]{4}$" % t[5:], prev.text) is not None and
                    loc(None, int(prev.text[-4:], 16)) in cm.insns)
            stack = stack + ("c" if code else "d",)
        elif t.startswith("pop "):
            kinds.setdefault(key, set()).add(stack[-1] if stack else "?")
            stack = stack[:-1]
        if ins.kind == "ret" and ins.cond is None or ins.kind in ("reti", "jpind"):
            continue
        if ins.kind in ("jp", "jr") and ins.target is not None:
            work.append((loc(key[0], ins.target), stack))
            if ins.cond is None and t.split()[0] != "djnz":
                continue
        if ins.kind in ("call", "rst") and ins.target is not None:
            if key in cm.rst_targets:       # a jump table: the rst's push is popped again
                for w in cm.rst_targets[key]:
                    work.append((loc(None, w), stack))
                continue
            work.append((loc(key[0], ins.target), stack + ("c",)))
            if ins.cond is None and ins.target in NO_RETURN:
                continue
        work.append((nxt, stack))
    return kinds


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


HANDLER_PREFIX = bytes([0x2A, 0x27, 0xE9])            # ld hl,($e927): the current object
HANDLER_CHECK = bytes([0x7E, 0xA7, 0xC0])              # then often ld a,(hl) / and a / ret nz


def object_handlers(cm):
    """Object handlers start with ld hl,($e927) (the current object) and are
    only reached through level data and object scripts - entered at the
    start, or after a following ld a,(hl) / and a / ret nz: take every such
    routine outside the known code that reads as code."""
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
                found = [k]
                if data[i + 3:i + 6] == HANDLER_CHECK:
                    found.append(loc(bank, a + 6))
                for e in found:
                    cm.entries.add(e)
                    cm.add(*e)
                code = cm.code_bytes()
            i = data.find(HANDLER_PREFIX, i + 1)


LEVEL_OBJECTS = 0x1E07     # per level: bank 5 table of the screens' object lists


def level_objects(cm):
    """The objects each level places ($1BD0-$1C00, $1DEA): $1E07 + 2 * level
    points at a table in bank 5 of up to 33 lists (one per screen), each of
    8-byte records up to a $FFFF word: +4 handler address, +6 its bank. Every
    handler of every level is an entry (only level 1's were ever traced)."""
    rom = cm.rom
    sp = Space(rom, 5)
    w = lambda a: sp[a] | sp[a + 1] << 8
    for level in range(8):
        table = rom[LEVEL_OBJECTS + 2 * level] | rom[LEVEL_OBJECTS + 2 * level + 1] << 8
        for screen in range(1, 34):
            rec = w(table + 2 * screen)
            if not 0x8000 <= rec < 0xC000:
                continue
            found = []
            for _ in range(64):
                if w(rec) == 0xFFFF:
                    break
                h, bank = w(rec + 4), sp[rec + 6]
                if bank > 15 or not 0x0100 <= h < 0xC000:
                    found = []          # not a list (past the level's screens)
                    break
                found.append(loc(bank, h))
                rec += 8
            for k in found:
                if k not in cm.insns:
                    cm.entries.add(k)
                    cm.add(*k)


def object_scripts(cm):
    """Object animation scripts (run by $32E6 / $3006): records of 5 bytes
    (a frame), or 00 + address (run that code, which continues the script
    3 bytes on), FF + address (go to that script), FE (end). Try every
    address a word in the same bank points at (and 3 / 5 bytes on, as objects
    keep their place in a script): a walk that ends properly, stays in the
    bank and whose every code address reads as code gives code entries. Code
    may be a known routine in the fixed ROM, and may not come back (the
    boss's death script calls the end of level, $5A4F, in
    data/code_entries.txt): a script may end with a code call."""
    code = cm.code_bytes()

    def walk(bank, start, sp):
        seen, todo, codes, n, ended = set(), [start], set(), 0, False
        while todo:
            a = todo.pop()
            called = False
            while True:
                if a in seen:
                    ended = True
                    break
                if not 0x8000 <= a < 0xBFFB or loc(bank, a) in code:
                    if called:              # (that code doesn't come back)
                        ended = True
                        break
                    return None
                seen.add(a)
                n += 1
                if n > 400:             # (level 8 has one of 160 records)
                    return None
                b = sp[a]
                called = False
                if b in (0x00, 0xFF):
                    w = sp[a + 1] | sp[a + 2] << 8
                    if not (0x8000 <= w < 0xC000 or (b == 0x00 and (None, w) in cm.insns)):
                        return None         # (fixed ROM: only known routines)
                    if b == 0xFF:
                        todo.append(w)
                        ended = True
                        break
                    codes.add(loc(bank, w))
                    called = True
                    a += 3
                elif b == 0xFE:
                    ended = True
                    break
                else:
                    a += 5
        return codes if ended and codes else None

    found = set()
    for bank in range(16):
        sp = Space(cm.rom, bank)
        refs = set()
        for x in range(0x8000, 0xBFFF):
            w = sp[x] | sp[x + 1] << 8
            if 0x8000 <= w < 0xC000:
                refs.add(w)
        for r in refs:
            for d in (0, 3, 5):
                c = walk(bank, r + d, sp)
                if c and all(k in cm.insns or (_looks_like_code(cm, k[0], k[1], strict=True) and
                                               _closure_ok(cm, k[0], k[1])) for k in c):
                    found.update(c)
    for k in sorted(found, key=lambda k: (-1 if k[0] is None else k[0], k[1])):
        if k not in cm.insns:
            cm.entries.add(k)
            cm.add(*k)


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
