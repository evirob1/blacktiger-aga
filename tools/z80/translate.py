"""Z80 -> 68020 translator for the Black Tiger main CPU.

See docs/TRANSLATOR.md for the register/memory mapping and the flag rules.

usage: python3 tools/z80/translate.py ROMS DYNAMIC.txt OUT.s [REPORT.txt] [--cycles]

--cycles: test build that counts Z80 T-states in a5 and puts a nop (instruction
boundary marker for the harness) in front of every translated instruction.
"""
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from z80 import codemap  # noqa: E402
from z80.timing import tstates  # noqa: E402

# 68k CCR bits used to model the Z80 flags we care about (H and N only matter
# to daa, which is handled as a pattern).
Z, S, V, C = 0x04, 0x08, 0x02, 0x11      # C includes X: we keep X == C
ALL = Z | S | V | C
# Flags assumed to be read by a caller after `ret` / a computed jump. P/V is left
# out: the program never tests parity/overflow across a return.
RET_LIVE = Z | S | C
CCR_MOVE = 0x0F                            # what move/tst/cmp/btst... may change (not X)

COND = {"nz": "ne", "z": "eq", "nc": "cc", "c": "cs", "po": "vc", "pe": "vs", "p": "pl", "m": "mi"}
NEG = {"ne": "eq", "eq": "ne", "cc": "cs", "cs": "cc", "vc": "vs", "vs": "vc", "pl": "mi", "mi": "pl"}
COND_USE = {"nz": Z, "z": Z, "nc": C, "c": C, "po": V, "pe": V, "p": S, "m": S}

# Hand-written in src/rt_core.s instead of translated: the scheduler loop and
# task switch ($00B3-$00F5) and sleep ($0116-$0134). Labels z_00b3 / z_0116 are
# provided by the runtime.
EXCLUDE = [(0x00B3, 0x00F6), (0x0116, 0x0135)]
RUNTIME_LABELS = {0x00B3, 0x0116}
# `ld c,(ix+15)`: the damage a hit does to the armour ($F3AD), just before
# it is taken off; PLAT_HIT may change it (test mode: none)
HIT_SITE = (None, 0x2F49)


def excluded(key):
    return key[0] is None and any(a <= key[1] < b for a, b in EXCLUDE)


# 16-bit pairs and the 8-bit halves: (data register, high byte?)
PAIR = {"bc": "d1", "de": "d2", "hl": "d3", "ix": "d4", "iy": "d5"}
R8 = {"a": ("d0", False), "b": ("d1", True), "c": ("d1", False), "d": ("d2", True),
      "e": ("d2", False), "h": ("d3", True), "l": ("d3", False),
      "ixh": ("d4", True), "ixl": ("d4", False), "iyh": ("d5", True), "iyl": ("d5", False)}


def label(bank, addr):
    if 0x8000 <= addr < 0xC000 and bank is not None:
        return "b%x_%04x" % (bank, addr)
    return "z_%04x" % addr


def sext16(v):
    v &= 0xFFFF
    return v - 0x10000 if v & 0x8000 else v


class T:
    """Translation of one instruction."""

    def __init__(self, lines=None, use=0, defs=0, ok=None, clob=None, d6=False, stack=False,
                 branch=None, end=False, note=None, succ=None):
        self.lines = lines or []
        self.use = use            # Z80 flags read
        self.defs = defs          # Z80 flags written
        self.ok = defs if ok is None else ok    # written flags the 68k code gets right
        self.clob = ALL if clob is None else clob  # 68k CCR bits changed
        self.d6 = d6              # code uses d6 (so flag saving can't)
        self.stack = stack        # code pushes/pops (so flag saving can't use the stack)
        self.branch = branch      # contains a conditional branch (flags must be ready before it)
        self.end = end
        self.note = note
        self.succ = succ or []    # extra successors (multi-way return tables)


class Translator:
    def __init__(self, rom, cm, out, cycles=False, bank_sites=(), sound=False):
        self.rom, self.cm, self.out = rom, cm, out
        self.sound = sound        # the sound CPU: plain memory, no banks or background RAM
        self.bank_sites = set(bank_sites)
        # stores into the background RAM window $C000-$CFFF (data/bg_stores.txt,
        # found by tools/harness/amiga_sim's BGSTALE report): base chosen at run time
        self.bg_stores = set()
        path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "data", "bg_stores.txt")
        if os.path.exists(path) and not sound:
            for line in open(path):
                f = line.split()
                if f and not line.startswith("#"):
                    self.bg_stores.add((None if f[0] == "ff" else int(f[0], 16), int(f[1], 16)))
        self.cycles = cycles      # test build: count Z80 T-states in a5, mark boundaries
        self.uid = 0
        self.problems = []
        self.ext_labels = set()   # labels used but outside the code map
        self.stacks = set()       # Z80 stack addresses loaded with ld sp,nn

    # ---------------------------------------------------------------- operands
    def tmp(self):
        self.uid += 1
        return "_t%d" % self.uid

    def mem(self, op, read=False):
        """Memory operand text for (hl), (bc), (de), (ix+d), (iy+d), ($nnnn).
        A read from a fixed address in the banked window $8000-$BFFF goes
        through a1 (current bank); everything else through a6."""
        inner = op[1:-1]
        if inner in ("hl", "bc", "de"):
            return "(a6,%s.w)" % PAIR[inner]
        m = re.match(r"(ix|iy)([+-]\d+)$", inner)
        if m:
            return "(%d,a6,%s.w)" % (int(m.group(2)), PAIR[m.group(1)])
        if inner.startswith("$"):
            a = int(inner[1:], 16)
            return "(%d,%s)" % (sext16(a), "a1" if read and 0x8000 <= a < 0xC000 else "a6")
        raise ValueError(op)

    def is_mem(self, op):
        return op.startswith("(") and op not in ("(c)",)

    def read8(self, op, into="d7"):
        """-> (lines, operand) giving op as a byte operand (may load into `into`)."""
        if op.startswith("$"):
            return [], "#$%s" % op[1:]
        if self.is_mem(op):
            return [], self.mem(op, read=True)
        reg, high = R8[op]
        if high:
            return ["move.w %s,%s" % (reg, into), "lsr.w #8,%s" % into], into
        return [], reg

    def write8(self, op, src):
        """lines storing byte operand src into op (flags: like move)."""
        if self.is_mem(op):
            return ["move.b %s,%s" % (src, self.mem(op))]
        reg, high = R8[op]
        if high:
            pre = []
            if src == reg:                      # ld h,l: copy before rotating
                pre, src = ["move.b %s,d7" % src], "d7"
            return pre + ["ror.w #8,%s" % reg, "move.b %s,%s" % (src, reg), "rol.w #8,%s" % reg]
        return ["move.b %s,%s" % (src, reg)]

    def on8(self, op, body):
        """apply `body(operand)` (a list of lines working on a byte operand
        and setting flags) to op, writing back without disturbing flags."""
        if self.is_mem(op):
            m = self.mem(op)
            return ["move.b %s,d7" % m] + body("d7") + ["move.w ccr,d6", "move.b d7,%s" % m,
                                                       "move.w d6,ccr"], True
        reg, high = R8[op]
        if high:
            return ["ror.w #8,%s" % reg] + body(reg) + ["move.w ccr,d7", "rol.w #8,%s" % reg,
                                                        "move.w d7,ccr"], False
        return body(reg), False

    def select_base(self, reg, into="a0"):
        """into = the base for the Z80 address in reg: a1 (current ROM bank)
        for $8000-$BFFF, the current background RAM bank (RT_BGPTR) for
        $C000-$CFFF, else a6. Keeps the CCR."""
        if self.sound:
            return ["movea.l a6,%s" % into]
        s, t = self.tmp(), self.tmp()
        return ["movea.w %s,%s" % (reg, into), "cmpa.w #-$3000,%s" % into, "bge.s %s" % s,
                "cmpa.w #-$4000,%s" % into, "movea.l a1,%s" % into, "blt.s %s" % t,
                "movea.l RT_BGPTR(a4),%s" % into, "bra.s %s" % t,
                s + ":", "movea.l a6,%s" % into, t + ":"]

    def static_bank_read(self, key, ins):
        """Reads that may hit the banked window without being seen in MAME:
        any pointer read in code that itself lives in a bank (it mostly reads
        its own bank's tables), and any read through HL, DE or BC in the fixed
        ROM (IX / IY point at objects in RAM)."""
        t = ins.text
        reads = re.match(r"(ld [a-z]+,|add a,|adc a,|sub |sbc a,|and |xor |or |cp |bit \d,)"
                         r"\((hl|de|bc|ix[+-]\d+|iy[+-]\d+)\)$", t)
        if not reads:
            return False
        return key[0] is not None or reads.group(2) in ("hl", "de", "bc")

    def bank_aware(self, key, ins, t):
        """An instruction seen reading the bank window through a register:
        choose the base at run time."""
        op = ins.text.split(" ")[0]
        if op not in ("ld", "add", "adc", "sub", "sbc", "and", "xor", "or", "cp", "bit"):
            self.problems.append("%s: bank read by '%s' not handled" % (label(*key), ins.text))
            return t
        if op == "ld" and not ins.text.split(",", 1)[1].startswith("(") and key not in self.bg_stores:
            self.problems.append("%s: bank read site is a store? (%s)" % (label(*key), ins.text))
            return t
        for i, l in enumerate(t.lines):
            m = re.search(r"\((-?\d+,)?a6,(d\d)\.w\)", l)
            if m:
                new = l[:m.start()] + "(%sa0,%s.w)" % (m.group(1) or "", m.group(2)) + l[m.end():]
                after = ["bsr bg_mark_%s" % m.group(2)] if key in self.bg_stores else []
                t.lines = t.lines[:i] + self.select_base(m.group(2)) + [new] + after + t.lines[i + 1:]
                t.clob |= CCR_MOVE      # cmpa: the flag analysis saves them where needed
                return t
        self.problems.append("%s: no indexed operand to make bank-aware (%s)" % (label(*key), ins.text))
        return t

    def c_to_x(self):
        return ["scs d6", "add.b d6,d6"]     # X := C

    # ---------------------------------------------------------------- per insn
    def tr(self, bank, ins, nxt_ins):
        t = ins.text.split(" ;")[0].strip()
        parts = t.split(" ", 1)
        op = parts[0]
        args = [a.strip() for a in parts[1].split(",")] if len(parts) > 1 else []
        k = ins.kind
        ctx = self.cm.bank_ctx.get(codemap.loc(bank, ins.pc))
        L = lambda a: self.target(bank if bank is not None else (ctx or None), a)

        if op == "nop" or op == "im":
            return T(["; " + t], clob=0)
        if op == "di":
            return T(["sf RT_IE(a4)"], clob=0)
        if op == "ei":
            return T(["bsr z80_ei"], clob=0)
        if op == "halt":
            return T(["bsr z80_halt"], clob=0)

        # ---- control flow
        if k in ("jp", "jr") and op != "djnz":
            if ins.cond:
                cc = COND[ins.cond]
                return T(["b%s %s" % (cc, L(ins.target))], use=COND_USE[ins.cond], clob=0,
                         branch=True)
            return T(["bra %s" % L(ins.target)], clob=0, end=True)
        if op == "djnz":
            return T(["sub.w #$100,d1", "cmp.w #$ff,d1", "bhi %s" % L(ins.target)], branch=True)
        if k == "call":
            if ins.cond:
                s = self.tmp()
                # flags afterwards are the callee's or the old ones: treat as unchanged
                return T(["b%s.s %s" % (NEG[COND[ins.cond]], s), "bsr %s" % L(ins.target),
                          s + ":"], use=COND_USE[ins.cond], clob=0)
            if ins.target in codemap.NO_RETURN:
                return T(["bra %s" % L(ins.target)], clob=0, end=True)
            tb = bank if bank is not None else (ctx or None)
            mw = self.multiway.get(codemap.loc(tb, ins.target))
            if mw:
                if ins.cond:
                    return T(["illegal ; MANUAL: conditional multi-way call"], clob=0,
                             note="conditional multi-way call")
                lines = ["bsr %s" % L(ins.target)]
                succ = []
                for k in range(max(mw) + 1):
                    r = codemap.loc(bank, ins.pc + ins.length + k)
                    if r in self.cm.insns:
                        lines.append("bra.w %s" % label(*r))
                        succ.append(r)
                    else:
                        lines += ["illegal", "illegal"]
                return T(lines, defs=ALL, ok=ALL, end=True, succ=succ)
            return T(["bsr %s" % L(ins.target)], defs=ALL, ok=ALL)
        if k == "rst":
            if self.sound and ins.target == SOUND_RST_TABLE:
                # jump table dispatch: pop hl (the table, after the rst) / the
                # lookup and jp (hl). The 68k return address isn't a Z80 address:
                # load the table's into HL and go straight to the lookup
                return T(["move.w #$%04x,d3" % (ins.pc + 1), "bra %s" % L(SOUND_RST_TABLE + 1)],
                         clob=0, end=True, succ=[codemap.loc(None, SOUND_RST_TABLE + 1)])
            return T(["bsr %s" % L(ins.target)], defs=ALL, ok=ALL)
        if k == "ret":
            if ins.cond:
                s = self.tmp()
                return T(["b%s.s %s" % (NEG[COND[ins.cond]], s), "rts", s + ":"],
                         use=COND_USE[ins.cond], clob=0)
            return T(["rts"], clob=0, end=True)
        if k == "reti":
            return T(["rts"], clob=0, end=True)
        if k == "jpind":
            src = (0xFF if bank is None else bank) << 16 | ins.pc
            return T(["movea.l #$%06x,a0" % src, "bra z80_jp_%s" % args[0][1:-1]],
                     clob=0, end=True)

        # ---- 8-bit loads
        if op == "ld" and len(args) == 2:
            d, s = args
            if d == "sp" and s.startswith("$"):
                # a task (re)starting on a fresh stack: one 68k stack per Z80 stack address
                self.stacks.add(int(s[1:], 16))
                return T(["lea zstk_%s(pc),sp" % s[1:], "; (stack reset)"], clob=0)
            if d == "sp" or s == "sp":
                return T(["illegal ; MANUAL: " + t], clob=0, note="sp load")
            if d in PAIR and not self.is_mem(s) and s.startswith("$"):
                return T(["move.w #%s,%s" % (s, PAIR[d])], clob=CCR_MOVE)
            if d in PAIR and self.is_mem(s):      # ld rr,(nn)
                return T(["move.w %s,%s" % (self.mem(s, read=True), PAIR[d]),
                          "rol.w #8,%s" % PAIR[d]])
            if s in PAIR and self.is_mem(d):      # ld (nn),rr
                r = PAIR[s]
                return T(["ror.w #8,%s" % r, "move.w %s,%s" % (r, self.mem(d)), "rol.w #8,%s" % r])
            if d in ("i", "r") or s in ("i", "r"):
                if d == "a":
                    return T(["bsr z80_ld_a_%s" % s], defs=Z | S, ok=Z | S, clob=ALL)
                return T(["; " + t], clob=0)
            if d in R8 or self.is_mem(d):
                pre, src = self.read8(s)
                return T(pre + self.write8(d, src), clob=CCR_MOVE)

        # ---- 16-bit misc
        if op == "push":
            # ld rr,<code address> / push rr: a hand-pushed return address (a later
            # ret jumps there), so push the 68k address of that code
            prev = self.cm.insns.get(codemap.loc(bank, ins.pc - 3))
            if prev is not None and args[0] in PAIR and prev.pc + prev.length == ins.pc and \
                    re.match(r"ld %s,\$[0-9a-f]{4}$" % args[0], prev.text):
                tb = bank if bank is not None else (ctx or None)
                tk = codemap.loc(tb, int(prev.text[-4:], 16))
                if tk in self.cm.insns:
                    self.problems.append("note: %s pushes code address $%04x as a return address" %
                                         (label(*codemap.loc(bank, ins.pc)), tk[1]))
                    return T(["pea %s(pc)" % label(*tk)], clob=0, stack=True)
            if args[0] == "af":
                return T(["move.b d0,-(sp)", "move.w ccr,-(sp)"], clob=CCR_MOVE, stack=True)
            return T(["move.w %s,-(sp)" % PAIR[args[0]]], clob=CCR_MOVE, stack=True)
        if op == "pop" and self.pops_code(codemap.loc(bank, ins.pc)):
            # consumes the return address (4 bytes on the 68k stack)
            if t == "pop hl" and codemap.loc(bank, ins.pc) in self.mw_pops:
                k = self.mw_pops[codemap.loc(bank, ins.pc)]
                return T(["move.l (sp)+,a0", "jmp (%d,a0)" % (4 * k),
                          "; multi-way return to return address + %d" % k], clob=0, end=True)
            return T(["addq.l #4,sp", "; drop return address (%s)" % t], clob=0)
        if op == "pop":
            if args[0] == "af":
                return T(["move.w (sp)+,d7", "move.b (sp)+,d0", "move.w d7,ccr"], defs=ALL, ok=ALL,
                         stack=True)
            return T(["move.w (sp)+,%s" % PAIR[args[0]]], clob=CCR_MOVE, stack=True)
        if op == "ex":
            if args == ["de", "hl"]:
                return T(["exg d2,d3"], clob=0)
            if args == ["af", "af'"]:
                return T(["move.w ccr,d6", "move.b d0,d7", "move.b RT_ALT_A(a4),d0",
                          "move.b d7,RT_ALT_A(a4)", "move.w RT_ALT_F(a4),d7",
                          "move.w d6,RT_ALT_F(a4)", "move.w d7,ccr"], defs=ALL, ok=ALL, d6=True)
            if args[0] == "(sp)":
                r = PAIR[args[1]]
                return T(["move.w (sp),d7", "move.w %s,(sp)" % r, "move.w d7,%s" % r],
                         clob=CCR_MOVE, stack=True)
        if op == "exx":
            # BC' lives in memory (a1 is the bank pointer); movem/exg leave the flags alone
            return T(["movem.w RT_ALT_BC(a4),d6", "movem.w d1,RT_ALT_BC(a4)", "exg d6,d1",
                      "exg d2,a2", "exg d3,a3"], clob=0, d6=True)
        if op in ("inc", "dec") and args[0] in PAIR:
            return T(["%s.w #1,%s" % ("addq" if op == "inc" else "subq", PAIR[args[0]])])
        if op == "inc" and args[0] == "sp" or op == "dec" and args[0] == "sp":
            return T(["illegal ; MANUAL: " + t], clob=0, note="sp arithmetic")
        if op in ("add", "adc", "sbc") and args[0] in PAIR:
            d, s = PAIR[args[0]], args[1]
            if s == "sp":
                return T(["illegal ; MANUAL: " + t], clob=0, note="sp arithmetic")
            s = PAIR[s]
            if op == "add":
                return T(["add.w %s,%s" % (s, d)], defs=C, ok=C)
            x = "addx" if op == "adc" else "subx"
            return T(self.c_to_x() + ["ori #4,ccr", "%s.w %s,%s" % (x, s, d)], use=C, defs=ALL,
                     ok=ALL, d6=True)

        # ---- 8-bit arithmetic and logic
        if op in ("add", "adc", "sub", "sbc", "and", "xor", "or", "cp"):
            s = args[-1]
            if op in ("add", "sub", "and", "or", "cp"):
                pre, src = self.read8(s)
                m = {"add": "add", "sub": "sub", "and": "and", "or": "or", "cp": "cmp"}[op]
                if op in ("and", "or"):
                    return T(pre + ["%s.b %s,d0" % (m, src)], defs=ALL, ok=Z | S | C,
                             clob=CCR_MOVE)
                if op == "cp":
                    return T(pre + ["cmp.b %s,d0" % src], defs=ALL, ok=ALL, clob=CCR_MOVE)
                return T(pre + ["%s.b %s,d0" % (m, src)], defs=ALL, ok=ALL)
            if op == "xor":
                if s == "a":
                    return T(["clr.b d0"], defs=ALL, ok=Z | S | C, clob=CCR_MOVE)
                pre, src = self.read8(s)
                if not src.startswith("d") and not src.startswith("#"):
                    pre, src = pre + ["move.b %s,d7" % src], "d7"
                return T(pre + ["eor.b %s,d0" % src], defs=ALL, ok=Z | S | C, clob=CCR_MOVE)
            # adc / sbc a,s : X := C, load operand, (Z set), addx/subx
            pre, src = self.read8(s)
            lines = self.c_to_x() + pre
            if src != "d7":
                lines.append("move.b %s,d7" % src)
            x = "addx" if op == "adc" else "subx"
            lines += ["ori #4,ccr", "%s.b d7,d0" % x]
            return T(lines, use=C, defs=ALL, ok=ALL, d6=True)
        if op in ("inc", "dec"):
            q = "addq.b #1,%s" if op == "inc" else "subq.b #1,%s"
            lines, d6 = self.on8(args[0], lambda r: [q % r])
            return T(lines, defs=Z | S | V, ok=Z | S | V, d6=d6)
        if op == "neg":
            return T(["neg.b d0"], defs=ALL, ok=ALL)
        if op == "cpl":
            return T(["not.b d0"], clob=CCR_MOVE)
        if op == "scf":
            return T(["ori #$11,ccr"], defs=C, ok=C, clob=C)
        if op == "ccf":
            return T(["eori #$11,ccr"], use=C, defs=C, ok=C, clob=C)
        if op == "daa":
            return T(["illegal ; MANUAL: lone daa"], clob=0, note="daa")

        # ---- rotates and shifts
        rot_a = {"rlca": "rol.b #1,d0", "rrca": "ror.b #1,d0"}
        if op in rot_a:
            return T([rot_a[op]], defs=C, ok=C, clob=CCR_MOVE)
        if op in ("rla", "rra"):
            return T(self.c_to_x() + ["%s.b #1,d0" % ("roxl" if op == "rla" else "roxr")],
                     use=C, defs=C, ok=C, d6=True)
        shifts = {"rlc": "rol", "rrc": "ror", "rl": "roxl", "rr": "roxr", "sla": "asl",
                  "sra": "asr", "srl": "lsr", "sll": "lsl"}
        if op in shifts:
            m = shifts[op]
            pre = self.c_to_x() if op in ("rl", "rr") else []
            extra = ["or.b #1,%s"] if op == "sll" else []
            lines, d6 = self.on8(args[0], lambda r: ["%s.b #1,%s" % (m, r)] + [e % r for e in extra])
            return T(pre + lines, use=C if pre else 0, defs=ALL, ok=Z | S | C,
                     d6=True if pre else d6)
        if op in ("bit", "set", "res"):
            n, o = int(args[0]), args[1]
            if self.is_mem(o):
                ea = self.mem(o)
            else:
                reg, high = R8[o]
                ea, n = reg, n + (8 if high else 0)
            mn = {"bit": "btst", "set": "bset", "res": "bclr"}[op]
            if op == "bit":
                return T(["btst #%d,%s" % (n, ea)], defs=Z, ok=Z, clob=Z)
            return T(["%s #%d,%s" % (mn, n, ea)], clob=Z)

        # ---- block ops, I/O
        if op in ("ldir", "lddr"):
            # source and destination bases chosen once (a2 = DE' meanwhile on the stack)
            s = self.tmp()
            q = "addq" if op == "ldir" else "subq"
            mark = [] if self.sound else ["bsr bg_mark_%s" % ("up" if op == "ldir" else "down")]
            return T(mark + ["move.l a2,-(sp)"] +
                     self.select_base("d2", "a2") + self.select_base("d3") +
                     [s + ":", "move.b (a0,d3.w),(a2,d2.w)",
                      "%s.w #1,d3" % q, "%s.w #1,d2" % q, "subq.w #1,d1", "bne.s %s" % s,
                      "movea.l (sp)+,a2"],
                     defs=V, ok=0, clob=ALL)
        if op in ("ldi", "ldd"):
            q = "addq" if op == "ldi" else "subq"
            mark = [] if self.sound else ["bsr bg_mark_d2"]
            return T(mark + ["move.l a2,-(sp)"] + self.select_base("d2", "a2") + self.select_base("d3") +
                     ["move.b (a0,d3.w),(a2,d2.w)", "movea.l (sp)+,a2", "%s.w #1,d3" % q,
                      "%s.w #1,d2" % q, "subq.w #1,d1"], defs=V, ok=0, clob=ALL)
        if op in ("cpir", "cpdr", "cpi", "cpd", "ini", "ind", "inir", "indr", "outi", "outd",
                  "otir", "otdr", "rld", "rrd"):
            return T(["bsr z80_%s" % op], use=C, defs=ALL, ok=ALL if op in ("rld", "rrd") else Z | C,
                     note="helper " + op)
        if op == "out":
            if args[0] == "(c)":
                return T(["bsr io_out_c"], clob=0)
            return T(["bsr io_out_%02x" % int(args[0][2:-1], 16)], clob=0)
        if op == "in":
            if args[-1] == "(c)":
                return T(["bsr io_in_c"], defs=ALL, ok=Z | S, note="in r,(c)")
            return T(["bsr io_in_%02x" % int(args[1][2:-1], 16)], clob=0)

        return T(["illegal ; UNHANDLED: " + t], clob=0, note="unhandled " + op)

    def target(self, bank, addr):
        b = bank if 0x8000 <= addr < 0xC000 else None
        if 0x8000 <= addr < 0xC000 and bank is None:
            self.problems.append("jump to banked $%04x with unknown bank" % addr)
            return "z80_unknown_bank"
        if b is None and any(a <= addr < e for a, e in EXCLUDE) and addr not in RUNTIME_LABELS:
            self.problems.append("jump into the hand-written scheduler at $%04x" % addr)
        elif (b, addr) not in self.cm.insns:
            self.ext_labels.add(label(b, addr))
        return label(b, addr)

    # ---------------------------------------------------------------- flow + liveness
    def pops_code(self, key):
        """Does the pop at key take a code address (4 bytes on the 68k)?"""
        if self.sound:
            return self.pop_kinds.get(key) == {"c"}
        return self.depths.get(key) == {0}

    def run(self):
        self.depths, self.multiway, conflicts = codemap.stack_depths(self.cm)
        if self.sound:
            # (followed through calls: escapes to a caller's frame are exact)
            self.pop_kinds = codemap.pop_kinds(self.cm, codemap.SOUND_ENTRY_POINTS)
            conflicts = ["%04x %s: pops %s" % (k[1], self.cm.insns[k].text, "/".join(sorted(v)))
                         for k, v in self.pop_kinds.items() if len(v) > 1 or "?" in v]
        self.problems += ["stack: " + c for c in conflicts if not c.startswith("00ec ")]
        self.mw_pops = {}
        for key, ins in self.cm.insns.items():
            if ins.text == "pop hl" and self.pops_code(key):
                k, p = 0, key[1] + 1
                nxt = self.cm.insns.get(codemap.loc(key[0], p))
                while nxt is not None and nxt.text == "inc hl":
                    k, p = k + 1, p + 1
                    nxt = self.cm.insns.get(codemap.loc(key[0], p))
                if nxt is not None and nxt.text == "jp (hl)":
                    self.mw_pops[key] = k
        keys = sorted(self.cm.insns, key=lambda k: (-1 if k[0] is None else k[0], k[1]))
        # daa fusion: add/adc/sub/sbc a,x directly followed by daa
        fused = {}
        for key in keys:
            ins = self.cm.insns[key]
            nk = codemap.loc(key[0], key[1] + ins.length)
            nxt = self.cm.insns.get(nk)
            if nxt and nxt.text == "daa" and ins.text.split(" ")[0] in ("add", "adc", "sub", "sbc") \
                    and (ins.text.startswith("sub ") or ins.text.split(" ", 1)[1].startswith("a,")):
                fused[key] = nk
        trs = {}
        for key in keys:
            ins = self.cm.insns[key]
            if excluded(key):
                trs[key] = T(clob=0)
            elif key in fused:
                trs[key] = self.tr_daa(key[0], ins)
            else:
                trs[key] = self.tr(key[0], ins, None)
                if not self.sound and ins.text not in ("ldir", "lddr", "ldi", "ldd") and (
                        key in self.bank_sites or key in self.bg_stores or self.static_bank_read(key, ins)):
                    trs[key] = self.bank_aware(key, ins, trs[key])
                if key == HIT_SITE and not self.sound:     # the damage of a hit, in c: the platform's test mode
                    trs[key].lines.append("PLAT_HIT")
                    trs[key].clob |= CCR_MOVE
        daa_keys = set(fused.values())
        for k in daa_keys:
            trs[k] = T(["; daa (fused with the add/sub above)"], clob=0)

        # successors
        succ = {}
        for key in keys:
            ins, t = self.cm.insns[key], trs[key]
            s = []
            if not t.end:
                s.append(codemap.loc(key[0], key[1] + ins.length))
            if ins.kind in ("jp", "jr") and ins.target is not None:
                s.append(codemap.loc(key[0], ins.target))
            succ[key] = s + t.succ
        # backward liveness of Z80 flags; ret / indirect / calls-out conservatively live
        live_in = {k: 0 for k in keys}
        live_out = {}
        changed = True
        while changed:
            changed = False
            for key in reversed(keys):
                ins, t = self.cm.insns[key], trs[key]
                if ins.kind in ("ret", "reti", "jpind") and t.end:
                    lo = RET_LIVE
                else:
                    lo = 0
                    for s in succ[key]:
                        lo |= live_in.get(s, ALL)
                    if ins.kind == "ret":       # conditional ret: may return to caller
                        lo |= RET_LIVE
                live_out[key] = lo
                li = t.use | (lo & ~t.defs & ALL)
                if li != live_in[key]:
                    live_in[key] = li
                    changed = True

        # emit
        out = []
        w = out.append
        w("; generated by tools/z80/translate.py - do not edit")
        prev_end = None
        region = "x"
        for key in keys:
            if excluded(key):
                prev_end = None
                continue
            ins, t = self.cm.insns[key], trs[key]
            reg = "fixed" if key[0] is None else "bank %d" % key[0]
            if reg != region:
                w("\n;==================== %s ====================" % reg)
                region = reg
            if prev_end is not None and prev_end != key:
                w("\tbra %s" % label(*prev_end))
            w("%s:\t\t\t\t; %04x  %s" % (label(*key), key[1], ins.text))
            lo = live_out[key]
            keep = lo & t.clob & ~t.defs        # flags the Z80 leaves alone but we change
            wrong = lo & t.defs & ~t.ok
            if wrong and not t.note:
                self.problems.append("%s: flags %02x needed but not modelled (%s)" %
                                     (label(*key), wrong, ins.text))
            if t.note:
                self.problems.append("%s: %s (%s)" % (label(*key), t.note, ins.text))
            lines = t.lines
            if keep and not t.branch:
                lines = self.preserve(lines, keep, t)
            elif keep and t.branch:
                lines = self.preserve_branch(lines, keep)
            if self.cycles:
                lines = self.add_cycles(key, ins, lines)
            for l in lines:
                w(("\t" + l) if not l.endswith(":") else l)
            prev_end = None if t.end else codemap.loc(key[0], key[1] + ins.length)
        if prev_end is not None:
            w("\tbra %s" % label(*prev_end))
        # computed-jump table: (bank << 16 | addr, bank $FF = fixed ROM), sorted.
        # Every instruction is listed: computed jumps also land on code that is
        # otherwise only reached by falling through.
        targets = sorted({k for k in self.cm.insns if not excluded(k)} |
                         {(None, a) for a in RUNTIME_LABELS},
                         key=lambda k: ((0xFF if k[0] is None else k[0]) << 16) | k[1])
        w("\n; computed-jump table: Z80 (bank,address) -> 68k code")
        w("\tcnop 0,4")
        w("z80_table_count:\tdc.l %d" % len(targets))
        w("z80_table:")
        for k in targets:
            w("\tdc.l $%06x,%s-z80_table" % (((0xFF if k[0] is None else k[0]) << 16) | k[1],
                                             label(*k)))
        if self.stacks:
            w("\n; task stacks (68k return addresses are 4 bytes: give each 1K)")
            w("\tcnop 0,4")
            for a in sorted(self.stacks):
                w("\tds.b 1024\nzstk_%04x:" % a)
        for e in sorted(self.ext_labels):
            w("; missing code at %s" % e)
            self.problems.append("branch to %s, which is not in the code map" % e)
        open(self.out, "w").write("\n".join(out) + "\n")
        return trs

    def add_cycles(self, key, ins, lines):
        """test build: boundary marker, T-state count, taken-branch extras."""
        base, extra = tstates(codemap.Space(self.rom, key[0] if key[0] is not None else
                                            self.cm.bank_ctx.get(key) or None), key[1])
        op = ins.text.split(" ")[0]
        out = ["nop"]
        if op in ("ldir", "lddr"):
            # 21 T-states per byte, 16 for the last. Each byte is a separate
            # instruction execution on the Z80, so interrupts can come in between.
            bne = next(i for i, l in enumerate(lines) if re.match(r"bne\.s _t\d+$", l))
            top = lines.index(lines[bne].split()[1] + ":")
            s = self.tmp()
            lines = (lines[:top + 1] + ["lea 21(a5),a5"] + lines[top + 1:bne] +
                     ["beq.s %s" % s, "nop", "bra.s %s" % lines[top][:-1], s + ":",
                      "lea -5(a5),a5"] + lines[bne + 1:])
            return out + lines
        out.append("lea %d(a5),a5" % base)
        if extra:
            # find the conditional transfer and add the extra time on its taken path
            for i, l in enumerate(lines):
                m = re.match(r"(b(?:ne|eq|cc|cs|vc|vs|pl|mi|hi|ls))(?:\.s)? (\S+)$", l)
                if m and not m.group(2).startswith("_t"):
                    cc = m.group(1)[1:]
                    inv = {"hi": "ls", "ls": "hi"}.get(cc) or NEG[cc]
                    s = self.tmp()
                    lines = lines[:i] + ["b%s.s %s" % (inv, s), "lea %d(a5),a5" % extra,
                                         "bra %s" % m.group(2), s + ":"] + lines[i + 1:]
                    break
                m = re.match(r"b(ne|eq|cc|cs|vc|vs|pl|mi|ls)\.s (_t\d+)$", l)
                if m:          # ret cc / call cc / flag-keeping djnz: skip around the transfer
                    lines = lines[:i + 1] + ["lea %d(a5),a5" % extra] + lines[i + 1:]
                    break
        return out + lines

    def preserve(self, lines, keep, t):
        """Keep the CCR bits in `keep` across `lines`."""
        merge = t.defs & t.clob & ALL
        if not t.stack:
            pre = ["move.w ccr,-(sp)"]
            if merge:
                post = ["move.w ccr,d7", "and.w #$%02x,d7" % (~keep & 0x1F),
                        "and.w #$%02x,(sp)" % keep, "or.w d7,(sp)", "move.w (sp)+,ccr"]
            else:
                post = ["move.w (sp)+,ccr"]
            return pre + lines + post
        assert not t.d6
        pre = ["move.w ccr,d6"]
        if merge:
            post = ["move.w ccr,d7", "and.w #$%02x,d7" % (~keep & 0x1F), "and.w #$%02x,d6" % keep,
                    "or.w d7,d6", "move.w d6,ccr"]
        else:
            post = ["move.w d6,ccr"]
        return pre + lines + post

    def preserve_branch(self, lines, keep):
        """djnz with live flags: restore the CCR on both paths."""
        tgt = lines[-1].split(" ", 1)[1]
        s = self.tmp()
        return ["move.w ccr,d6"] + lines[:-1] + ["bls.s %s" % s, "move.w d6,ccr", "bra %s" % tgt,
                                                  s + ":", "move.w d6,ccr"]

    def tr_daa(self, bank, ins):
        op, a = ins.text.split(" ", 1)
        s = a.split(",")[-1]
        pre, src = self.read8(s)
        lines = []
        if op in ("adc", "sbc"):
            lines += self.c_to_x()
        lines += pre
        if src != "d7":
            lines.append("move.b %s,d7" % src)
        if op in ("add", "sub"):
            lines.append("move #4,ccr")        # X=0, Z=1
        else:
            lines.append("ori #4,ccr")
        lines.append("%s d7,d0" % ("abcd" if op in ("add", "adc") else "sbcd"))
        return T(lines, use=C if op in ("adc", "sbc") else 0, defs=ALL, ok=Z | C, d6=True)


# the sound CPU (--sound): the YM2203 register writes ($0153: wait for the
# chip, then write; $0162) and the idle loop after the start-up ($0009: back
# to the platform; everything else happens in the timer interrupt) are
# hand-written (src/sound.s)
SOUND_EXCLUDE = [(0x0009, 0x000C), (0x0153, 0x016D)]
SOUND_RUNTIME = {0x0009, 0x0153, 0x0162}
SOUND_RST_TABLE = codemap.SOUND_RST_TABLE


def sound_names(text):
    """The sound translation's names, apart from the game's: s_xxxx, snd_*."""
    text = re.sub(r"\bz_([0-9a-f]{4})\b", r"s_\1", text)
    text = re.sub(r"\b_t(\d+)\b", r"_s\1", text)
    text = re.sub(r"\bzstk_", "sstk_", text)
    return re.sub(r"\bz80_", "snd_", text)


def main():
    global EXCLUDE, RUNTIME_LABELS
    sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    import bt_rom
    sound = "--sound" in sys.argv
    if sound:
        EXCLUDE, RUNTIME_LABELS = SOUND_EXCLUDE, SOUND_RUNTIME
    rom = bt_rom.load_roms(sys.argv[1])["audiocpu" if sound else "maincpu"]
    cm = codemap.build(rom, sys.argv[2], sound=sound)
    cycles = "--cycles" in sys.argv
    args = [a for a in sys.argv if a not in ("--cycles", "--sound")]
    sys.argv = args
    sites = []
    bank_file = os.path.join(os.path.dirname(os.path.abspath(sys.argv[2])), "bank_reads.txt")
    if os.path.exists(bank_file) and not sound:
        for line in open(bank_file):
            f = line.split()
            if f and not line.startswith("#"):
                sites.append((None if f[0] == "ff" else int(f[0], 16), int(f[1], 16)))
    tr = Translator(rom, cm, sys.argv[3], cycles, sites, sound)
    tr.run()
    if sound:
        text = sound_names(open(sys.argv[3]).read())
        open(sys.argv[3], "w").write(text)
    rep = sys.argv[4] if len(sys.argv) > 4 else None
    probs = sorted(set(tr.problems))
    if rep:
        open(rep, "w").write("\n".join(probs) + "\n")
    print("%d instructions translated, %d problems%s" %
          (len(cm.insns), len(probs), (" (see %s)" % rep) if rep else ""))


if __name__ == "__main__":
    main()
