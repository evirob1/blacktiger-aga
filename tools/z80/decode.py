"""Z80 instruction decoder (all documented opcodes plus the common undocumented
IX/IY half-register forms), following the x/y/z/p/q scheme from
"Decoding Z80 Opcodes" (z80.info).

decode(mem, pc) -> Insn(pc, length, text, kind, target, cond)
  kind: 'seq' | 'jp' | 'jr' | 'call' | 'ret' | 'reti' | 'rst' | 'jpind' | 'halt'
  target: absolute destination for jp/jr/call/rst, else None
  cond: condition string ('nz','z','nc','c','po','pe','p','m') or None
"""
from collections import namedtuple

Insn = namedtuple("Insn", "pc length text kind target cond")

R = ["b", "c", "d", "e", "h", "l", "(hl)", "a"]
RP = ["bc", "de", "hl", "sp"]
RP2 = ["bc", "de", "hl", "af"]
CC = ["nz", "z", "nc", "c", "po", "pe", "p", "m"]
ALU = ["add a,", "adc a,", "sub ", "sbc a,", "and ", "xor ", "or ", "cp "]
ROT = ["rlc", "rrc", "rl", "rr", "sla", "sra", "sll", "srl"]
BLI = {(4, 0): "ldi", (4, 1): "cpi", (4, 2): "ini", (4, 3): "outi",
       (5, 0): "ldd", (5, 1): "cpd", (5, 2): "ind", (5, 3): "outd",
       (6, 0): "ldir", (6, 1): "cpir", (6, 2): "inir", (6, 3): "otir",
       (7, 0): "lddr", (7, 1): "cpdr", (7, 2): "indr", (7, 3): "otdr"}


def decode(mem, pc):
    """mem: indexable by 16-bit address (bytes-like or object with __getitem__)."""
    p = pc
    prefix = None
    op = mem[p & 0xFFFF]
    if op in (0xDD, 0xFD):
        prefix = "ix" if op == 0xDD else "iy"
        p += 1
        op = mem[p & 0xFFFF]
        if op in (0xDD, 0xFD, 0xED):          # prefix ignored: treat as 1-byte nop
            return Insn(pc, 1, "nop ; ignored prefix", "seq", None, None)
    if op == 0xED:
        return _ed(mem, pc, p + 1)
    if op == 0xCB:
        return _cb(mem, pc, p + 1, prefix)

    p += 1
    x, y, z = op >> 6, (op >> 3) & 7, op & 7
    pp, q = y >> 1, y & 1

    def n8():
        nonlocal p
        v = mem[p & 0xFFFF]
        p += 1
        return v

    def n16():
        lo = n8()
        return lo | n8() << 8

    def d8():
        v = n8()
        return v - 256 if v > 127 else v

    def reg(i, allow_half=True):
        """register i with IX/IY substitution."""
        if prefix is None:
            return R[i]
        if i == 6:
            d = d8()
            return "(%s%+d)" % (prefix, d)
        if allow_half and i in (4, 5):
            return prefix + ("h" if i == 4 else "l")
        return R[i]

    def rp(i):
        return prefix if (prefix and i == 2) else RP[i]

    def rp2(i):
        return prefix if (prefix and i == 2) else RP2[i]

    def fin(text, kind="seq", target=None, cond=None):
        return Insn(pc, p - pc, text, kind, target, cond)

    if x == 0:
        if z == 0:
            if y == 0:
                return fin("nop")
            if y == 1:
                return fin("ex af,af'")
            if y == 2:
                d = d8()
                return fin("djnz $%04x" % ((p + d) & 0xFFFF), "jr", (p + d) & 0xFFFF, "b")
            d = d8()
            t = (p + d) & 0xFFFF
            if y == 3:
                return fin("jr $%04x" % t, "jr", t)
            return fin("jr %s,$%04x" % (CC[y - 4], t), "jr", t, CC[y - 4])
        if z == 1:
            if q == 0:
                return fin("ld %s,$%04x" % (rp(pp), n16()))
            return fin("add %s,%s" % (rp(2), rp(pp)))
        if z == 2:
            if q == 0:
                if pp == 0:
                    return fin("ld (bc),a")
                if pp == 1:
                    return fin("ld (de),a")
                if pp == 2:
                    return fin("ld ($%04x),%s" % (n16(), rp(2)))
                return fin("ld ($%04x),a" % n16())
            if pp == 0:
                return fin("ld a,(bc)")
            if pp == 1:
                return fin("ld a,(de)")
            if pp == 2:
                return fin("ld %s,($%04x)" % (rp(2), n16()))
            return fin("ld a,($%04x)" % n16())
        if z == 3:
            return fin(("inc %s" if q == 0 else "dec %s") % rp(pp))
        if z == 4:
            return fin("inc %s" % reg(y))
        if z == 5:
            return fin("dec %s" % reg(y))
        if z == 6:
            r = reg(y)
            return fin("ld %s,$%02x" % (r, n8()))
        return fin(["rlca", "rrca", "rla", "rra", "daa", "cpl", "scf", "ccf"][y])
    if x == 1:
        if z == 6 and y == 6:
            return fin("halt", "halt")
        # with an (ix+d) operand the other register is the plain one
        if prefix and (y == 6 or z == 6):
            if y == 6:
                return fin("ld %s,%s" % (reg(6), R[z]))
            return fin("ld %s,%s" % (R[y], reg(6)))
        return fin("ld %s,%s" % (reg(y), reg(z)))
    if x == 2:
        return fin(ALU[y] + reg(z))
    # x == 3
    if z == 0:
        return fin("ret %s" % CC[y], "ret", None, CC[y])
    if z == 1:
        if q == 0:
            return fin("pop %s" % rp2(pp))
        if pp == 0:
            return fin("ret", "ret")
        if pp == 1:
            return fin("exx")
        if pp == 2:
            return fin("jp (%s)" % rp(2), "jpind")
        return fin("ld sp,%s" % rp(2))
    if z == 2:
        t = n16()
        return fin("jp %s,$%04x" % (CC[y], t), "jp", t, CC[y])
    if z == 3:
        if y == 0:
            t = n16()
            return fin("jp $%04x" % t, "jp", t)
        if y == 2:
            return fin("out ($%02x),a" % n8())
        if y == 3:
            return fin("in a,($%02x)" % n8())
        if y == 4:
            return fin("ex (sp),%s" % rp(2))
        if y == 5:
            return fin("ex de,hl")
        if y == 6:
            return fin("di")
        return fin("ei")
    if z == 4:
        t = n16()
        return fin("call %s,$%04x" % (CC[y], t), "call", t, CC[y])
    if z == 5:
        if q == 0:
            return fin("push %s" % rp2(pp))
        if pp == 0:
            t = n16()
            return fin("call $%04x" % t, "call", t)
        return fin("nop ; bad prefix")
    if z == 6:
        return fin(ALU[y] + "$%02x" % n8())
    return fin("rst $%02x" % (y * 8), "rst", y * 8)


def _cb(mem, pc, p, prefix):
    if prefix:
        d = mem[p & 0xFFFF]
        d = d - 256 if d > 127 else d
        op = mem[(p + 1) & 0xFFFF]
        length = p + 2 - pc
        operand = "(%s%+d)" % (prefix, d)
    else:
        op = mem[p & 0xFFFF]
        length = p + 1 - pc
        operand = R[op & 7]
    x, y = op >> 6, (op >> 3) & 7
    if x == 0:
        t = "%s %s" % (ROT[y], operand)
    else:
        t = "%s %d,%s" % (["", "bit", "res", "set"][x], y, operand)
    if prefix and (op & 7) != 6 and x != 1:
        t += " ; also -> %s" % R[op & 7]
    return Insn(pc, length, t, "seq", None, None)


def _ed(mem, pc, p):
    op = mem[p & 0xFFFF]
    p += 1
    x, y, z = op >> 6, (op >> 3) & 7, op & 7
    pp, q = y >> 1, y & 1

    def n16():
        return mem[p & 0xFFFF] | mem[(p + 1) & 0xFFFF] << 8

    if x == 1:
        if z == 0:
            return Insn(pc, p - pc, "in %s(c)" % ("" if y == 6 else R[y] + ","), "seq", None, None)
        if z == 1:
            return Insn(pc, p - pc, "out (c),%s" % ("0" if y == 6 else R[y]), "seq", None, None)
        if z == 2:
            return Insn(pc, p - pc, ("sbc hl,%s" if q == 0 else "adc hl,%s") % RP[pp], "seq", None, None)
        if z == 3:
            a = n16()
            t = ("ld ($%04x),%s" if q == 0 else "ld %s,($%04x)")
            t = t % ((a, RP[pp]) if q == 0 else (RP[pp], a))
            return Insn(pc, p + 2 - pc, t, "seq", None, None)
        if z == 4:
            return Insn(pc, p - pc, "neg", "seq", None, None)
        if z == 5:
            return Insn(pc, p - pc, "reti" if y == 1 else "retn", "reti", None, None)
        if z == 6:
            return Insn(pc, p - pc, "im %d" % [0, 0, 1, 2, 0, 0, 1, 2][y], "seq", None, None)
        return Insn(pc, p - pc, ["ld i,a", "ld r,a", "ld a,i", "ld a,r", "rrd", "rld", "nop", "nop"][y],
                    "seq", None, None)
    if x == 2 and z <= 3 and y >= 4:
        return Insn(pc, p - pc, BLI[(y, z)], "seq", None, None)
    return Insn(pc, p - pc, "nop ; undefined ED %02x" % op, "seq", None, None)
