#!/usr/bin/env python3
"""Generate DEFLATE test vectors for the Deflate.hs timing probe.

Writes, into vectors/ beside this script:
  NAME.deflate.hex   the raw DEFLATE stream, one byte per line ($readmemh)
  NAME.expected.hex  the expected output bytes
  NAME.json          lengths, block types seen, sha256

Streams come from zlib with strategy Z_FIXED (fixed-Huffman blocks), which
is exactly what Deflate.hs decodes, plus hand-packed streams for branches
zlib never emits (a stored block by hand, a wrong NLEN, a too-far distance,
and a dynamic block as the negative control).
"""
import hashlib
import json
import zlib
from pathlib import Path

HERE = Path(__file__).resolve().parent
OUT = HERE / "vectors"


def fixed_stream(data: bytes) -> bytes:
    c = zlib.compressobj(9, zlib.DEFLATED, -15, 9, zlib.Z_FIXED)
    return c.compress(data) + c.flush()


def block_types(stream: bytes):
    """Walk block headers of a raw DEFLATE stream, returning BTYPE values.

    Huffman codes are transmitted canonical-MSB-first (RFC 1951 3.1.1);
    field values and extra bits are LSB-first. This walker reads one bit at
    a time and accumulates the canonical code directly.
    """
    pos, bitpos = 0, 0
    types = []

    def read_bits(n):
        nonlocal pos, bitpos
        v = 0
        for i in range(n):
            byte = stream[pos]
            bit = (byte >> (bitpos % 8)) & 1
            v |= bit << i
            bitpos += 1
            if bitpos % 8 == 0:
                pos += 1
        return v

    def read_code(max_len):
        c = 0
        for _ in range(max_len):
            c = (c << 1) | read_bits(1)  # canonical MSB first
            yield c

    final = False
    while not final:
        final = bool(read_bits(1))
        btype = read_bits(2)
        types.append(btype)
        if btype == 0:
            align = (bitpos + 7) // 8
            pos, bitpos = align, align * 8
            ln = int.from_bytes(stream[pos : pos + 2], "little")
            pos += 4 + ln
            bitpos = pos * 8
        elif btype == 1:
            while True:
                sym, ln = None, 0
                for c in read_code(9):
                    ln += 1
                    if ln == 7 and c <= 0x17:
                        sym = 256 + c
                    elif ln == 8 and 0x30 <= c <= 0xBF:
                        sym = c - 0x30
                    elif ln == 8 and 0xC0 <= c <= 0xC7:
                        sym = 280 + (c - 0xC0)
                    elif ln == 9 and c >= 0x190:
                        sym = 144 + (c - 0x190)
                    if sym is not None:
                        break
                if sym is None:
                    raise ValueError("bad fixed code")
                if sym <= 255:
                    continue
                if sym == 256:
                    break
                idx = sym - 257
                read_bits((0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2,
                           3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0)[idx])
                d = 0
                for _ in range(5):
                    d = (d << 1) | read_bits(1)
                read_bits((0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6,
                           7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13)[d])
        else:
            raise ValueError("dynamic stream: caller must expect it")
    return types


class BitWriter:
    def __init__(self):
        self.bytes_ = bytearray()
        self.acc, self.n = 0, 0

    def put(self, value, width):
        for i in range(width):
            bit = (value >> i) & 1
            self.acc |= bit << self.n
            self.n += 1
            if self.n == 8:
                self.bytes_.append(self.acc)
                self.acc, self.n = 0, 0

    def done(self):
        if self.n:
            self.bytes_.append(self.acc)
            self.acc, self.n = 0, 0
        return bytes(self.bytes_)


def rev(value, width):
    r = 0
    for i in range(width):
        r = (r << 1) | ((value >> i) & 1)
    return r


def fixed_symbol(bw, sym):
    """Write a fixed-Huffman symbol LSB-first."""
    if sym <= 143:
        bw.put(rev(0x30 + sym, 8), 8)
    elif sym <= 255:
        bw.put(rev(0x190 + (sym - 144), 9), 9)
    elif sym <= 279:
        bw.put(rev(sym - 256, 7), 7)
    else:
        bw.put(rev(0xC0 + (sym - 280), 8), 8)


def hand_stored(bfinal, payload, corrupt_nlen=False):
    bw = BitWriter()
    bw.put(1 if bfinal else 0, 1)
    bw.put(0, 2)
    bw.done()  # byte-align
    out = bytearray(bw.done())
    ln = len(payload)
    nlen = (~ln) & 0xFFFF
    if corrupt_nlen:
        nlen ^= 1
    out += ln.to_bytes(2, "little") + nlen.to_bytes(2, "little") + payload
    return bytes(out)


def hand_far_distance():
    """A fixed block: emit 'A', then length-3 at distance 24577+extra (too far)."""
    bw = BitWriter()
    bw.put(1, 1)
    bw.put(1, 2)
    fixed_symbol(bw, ord("A"))
    fixed_symbol(bw, 257)  # length 3, no extra bits
    bw.put(rev(29, 5), 5)  # distance code 29 (base 24577)
    bw.put(0x1FFE, 13)  # its 13 extra bits; distance 24577 + 8191 > produced
    fixed_symbol(bw, 256)  # EOB
    return bw.done()


LOREM = (
    "the quick brown fox jumps over the lazy dog. "
    "packing arbitrary prose tests literals and short copies; "
    "the window keeps every byte so distances reach back through it. "
) * 12


def main():
    OUT.mkdir(exist_ok=True)
    cases = {}
    def add(name, stream, expected=None, reject=False):
        if not reject:
            inflated = zlib.decompress(stream, -15)
            if expected is not None:
                assert inflated == expected, name
            expected = inflated
        cases[name] = (stream, expected or b"", reject)

    for name, data in [("hello", b"Hello, DEFLATE on the Tang Nano 20K! " * 3),
                       ("abc", b"abc" * 2000), ("lorem", (LOREM.encode()*2)[:2560]),
                       ("big", (LOREM.encode()*20)[:16384]), ("empty", b""),
                       ("wrap-64k", bytes(range(256))*400), ("overlap-one", b"A"*70000),
                       ("all-literals", bytes(range(256)))]:
        add(name, fixed_stream(data), data)
    add("stored", hand_stored(True, bytes(range(64)) + b"\xff"*32 + b"tail bytes here"))
    add("stored-empty", hand_stored(True, b""))
    add("stored-multiple", hand_stored(False,b"") + hand_stored(False,b"abc") + hand_stored(True,b""))
    add("mixed-blocks", hand_stored(False,b"hello") + fixed_stream(b"world"))
    add("stored-max", hand_stored(False, bytes(range(255))*257) + hand_stored(True,b"end"))
    add("hand-far-distance", hand_far_distance(), b"A", True)
    add("hand-bad-nlen", hand_stored(True,b"ABC",True), reject=True)
    add("zlib-stored", fixed_stream(bytes((i*137+11)%251 for i in range(300))))
    dyn = zlib.compress((LOREM.encode()*2)[:2560],9)[2:-4]
    assert dyn[0] & 6 == 4
    add("dynamic", dyn, reject=True)
    add("reserved-block", b"\x07", reject=True)
    for symbol in (286,287):
        bw=BitWriter(); bw.put(3,3); fixed_symbol(bw,symbol)
        add(f"reserved-length-{symbol}",bw.done(),reject=True)
    for code in (30,31):
        bw=BitWriter(); bw.put(3,3); fixed_symbol(bw,257); bw.put(rev(code,5),5)
        add(f"reserved-distance-{code}",bw.done(),reject=True)
    # Full 32 KiB distance and overlapping copies, including address wrap.
    prefix=bytes((i*73+i//251)%256 for i in range(32768))
    bw=BitWriter(); bw.put(3,3); fixed_symbol(bw,285); bw.put(rev(29,5),5); bw.put(8191,13); fixed_symbol(bw,256)
    add("distance-32768",hand_stored(False,prefix)+bw.done(),prefix+prefix[:258])
    # Exact final-byte EOB: six nine-bit literals leave exactly seven bits.
    bw=BitWriter(); bw.put(3,3)
    for _ in range(6): fixed_symbol(bw,255)
    fixed_symbol(bw,256)
    add("eob-seven-bits",bw.done(),b"\xff"*6)
    # A fixed EOB followed by a stored header which starts mid-byte.
    bw=BitWriter(); bw.put(2,3); fixed_symbol(bw,256); bw.put(1,3)
    add("fixed-to-stored",bw.done()+b"\x03\x00\xfc\xffabc",b"abc")
    # Exercise every length and distance code at both extra-bit extrema.
    le=[0]*8+[1]*4+[2]*4+[3]*4+[4]*4+[5]*4+[0]
    de=[0]*4+[e for e in range(1,14) for _ in range(2)]
    bw=BitWriter(); bw.put(3,3)
    for code,extra in enumerate(le):
        for value in (0,(1<<extra)-1):
            fixed_symbol(bw,257+code); bw.put(value,extra); bw.put(0,5)
    for code,extra in enumerate(de):
        for value in (0,(1<<extra)-1):
            fixed_symbol(bw,257); bw.put(rev(code,5),5); bw.put(value,extra)
    fixed_symbol(bw,256)
    add("all-copy-codes",hand_stored(False,prefix)+bw.done())
    # Every byte truncation of a short fixed/stored stream. zlib supplies the
    # output prefix, but our explicit EOF is responsible for the error flag.
    for kind,stream in [("fixed",fixed_stream(b"hello hello hello")),("stored",hand_stored(True,b"abc"))]:
        for n in range(len(stream)):
            dec=zlib.decompressobj(-15); partial=dec.decompress(stream[:n])
            add(f"truncated-{kind}-{n}",stream[:n],partial,True)
    manifest={}
    for name,(stream,expected,reject) in cases.items():
        (OUT/f"{name}.deflate.hex").write_text("".join(f"{b:02x}\n" for b in stream))
        (OUT/f"{name}.expected.hex").write_text("".join(f"{b:02x}\n" for b in expected))
        manifest[name]=dict(deflate_bytes=len(stream),expected_bytes=len(expected),must_reject=reject,
                           deflate_sha256=hashlib.sha256(stream).hexdigest(),expected_sha256=hashlib.sha256(expected).hexdigest())
    (OUT/"vectors.json").write_text(json.dumps(manifest,indent=2)+"\n")
    (OUT/"cases.txt").write_text("".join(f"{name} {int(reject)}\n" for name,(_,_,reject) in cases.items()))
    print(f"Generated {len(cases)} zlib-oracle and rejection cases")

if __name__ == "__main__":
    main()
