# A seeded differential fuzz of the two snappy decoders. Every stream is
# decoded by the C library and by the Mojo decoder (twice, with different
# bytes around the input) into a window of a sentinel-filled buffer of the
# declared length + {0, 1, 63, 64, 65} and the declared length - 1.
#
# - No decoder may write a byte outside its window.
# - The two Mojo runs must agree: a read outside the input would show up as a
#   difference.
# - Both decoders must accept the same streams, with equal outputs.
#
# The generators and seeds are fixed, so every run decodes the same streams:
# - test_fuzz_structured: 6000 tag streams (literals, copy-1/2/4 with offsets
#   near 0, 1, 2, 8, 16, 32, 64 and the produced length; some with a wrong
#   preamble, short literals or a cut tail).
# - test_fuzz_random_bytes: 3000 random streams of 0..59 bytes.
# - test_every_prefix_and_corruption: every prefix of a C-compressed 300-byte
#   payload and four random single-byte corruptions per position.

from std.testing import TestSuite, assert_equal, assert_true

from komira_parquet_codec.snappy import (
    SnappyDecoder,
    set_snappy_decoder,
    snappy_compress,
    snappy_decompress,
    snappy_max_compressed_length,
)

comptime G = 96


struct Rng(Movable):
    var s: UInt64

    def __init__(out self, seed: UInt64):
        self.s = seed

    def next(mut self) -> UInt64:
        self.s = self.s * 6364136223846793005 + 1442695040888963407
        var x = self.s
        x ^= x >> 33
        return x

    def below(mut self, n: Int) -> Int:
        return Int(self.next() % UInt64(n))


def put_varint(mut out: List[UInt8], v: Int):
    var x = UInt64(v)
    while x >= 128:
        out.append(UInt8((x & 127) | 128))
        x >>= 7
    out.append(UInt8(x))


def pick_len(mut r: Rng, hi: Int) -> Int:
    var c = r.below(10)
    if c < 7:
        return 1 + r.below(70)
    if c < 9:
        return 1 + r.below(hi)
    return 60 + r.below(8)


def pick_off(mut r: Rng, produced: Int) -> Int:
    var c = r.below(14)
    if c == 0: return 0
    if c == 1: return 1
    if c == 2: return 2
    if c == 3: return 3 + r.below(5)
    if c == 4: return 8
    if c == 5: return 15 + r.below(3)
    if c == 6: return 31 + r.below(3)
    if c == 7: return 63 + r.below(3)
    if c == 8: return produced
    if c == 9: return produced + 1
    if c == 10: return produced - 1 if produced > 0 else 1
    if c == 11: return 1 + r.below(2048)
    if c == 12: return 1 + r.below(70000)
    return 1 + r.below(produced + 1)


def gen_stream(mut r: Rng) -> List[UInt8]:
    var body = List[UInt8]()
    var produced = 0
    var ntags = 1 + r.below(24)
    for _ in range(ntags):
        var t = r.below(4)
        if t == 0:
            var n = pick_len(r, 300)
            if n <= 60:
                body.append(UInt8((n - 1) << 2))
            else:
                var extra = 1
                if n > 256: extra = 2
                if r.below(6) == 0: extra = 1 + r.below(4)
                body.append(UInt8((59 + extra) << 2))
                var m = n - 1
                for k in range(extra):
                    body.append(UInt8((m >> (8 * k)) & 255))
            var lie = r.below(12) == 0
            var nbytes = n - 1 if lie else n
            for _ in range(nbytes):
                body.append(UInt8(r.below(256)))
            produced += n
        elif t == 1:
            var n = 4 + r.below(8)
            var off = pick_off(r, produced) % 2048
            body.append(UInt8(((off >> 8) << 5) | ((n - 4) << 2) | 1))
            body.append(UInt8(off & 255))
            produced += n
        elif t == 2:
            var n = pick_len(r, 64)
            if n > 64: n = 64
            var off = pick_off(r, produced) % 65536
            body.append(UInt8(((n - 1) << 2) | 2))
            body.append(UInt8(off & 255))
            body.append(UInt8(off >> 8))
            produced += n
        else:
            var n = pick_len(r, 64)
            if n > 64: n = 64
            var off = pick_off(r, produced)
            body.append(UInt8(((n - 1) << 2) | 3))
            for k in range(4):
                body.append(UInt8((off >> (8 * k)) & 255))
            produced += n
    var out = List[UInt8]()
    var c = r.below(20)
    var u = produced
    if c == 0: u = produced + 1 + r.below(70)
    elif c == 1: u = produced - 1 - r.below(70) if produced > 70 else 0
    elif c == 2: u = 0
    elif c == 3: u = 0xFFFFFFFF
    elif c == 4: u = 1 << 21
    put_varint(out, u)
    for b in body:
        out.append(b)
    if r.below(15) == 0 and len(out) > 2:
        out.resize(len(out) - 1 - r.below(len(out) - 1), 0)
    return out^


def run_one(stream: List[UInt8], mut viol: Int, mut mism: Int, mut dis: Int, mut okc: Int) raises:
    # declared length (best-effort varint parse)
    var u = 0
    var shift = 0
    var i = 0
    while i < len(stream) and i < 5:
        u |= Int(stream[i] & 127) << shift
        shift += 7
        i += 1
        if stream[i - 1] < 128:
            break
    var base = u if u <= (1 << 20) else 100
    var sizes = List[Int]()
    sizes.append(base); sizes.append(base + 1); sizes.append(base + 63)
    sizes.append(base + 64); sizes.append(base + 65)
    if base > 0: sizes.append(base - 1)
    for cap in sizes:
        var outs = List[List[UInt8]]()
        var oks = List[Bool]()
        for d in range(3):
            # d0=C, d1=Mojo/src surround AA, d2=Mojo/src surround 55
            var src = List[UInt8]()
            var sur: UInt8 = 0xAA if d != 2 else 0x55
            for _ in range(8): src.append(sur)
            for b in stream: src.append(b)
            for _ in range(G): src.append(sur)
            var s = Span(src)[8 : 8 + len(stream)]
            var buf = List[UInt8]()
            for _ in range(G + cap + G): buf.append(0xCC)
            var dstw = Span(buf)[G : G + cap]
            set_snappy_decoder(SnappyDecoder.C_LIBRARY if d == 0 else SnappyDecoder.MOJO)
            var ok = True
            var n = 0
            try:
                n = snappy_decompress(s, dstw)
            except:
                ok = False
            set_snappy_decoder(SnappyDecoder.C_LIBRARY)
            for k in range(G):
                if buf[k] != 0xCC or buf[G + cap + k] != 0xCC:
                    viol += 1
                    break
            var o = List[UInt8]()
            if ok:
                for k in range(n): o.append(buf[G + k])
            outs.append(o^)
            oks.append(ok)
        if oks[1] != oks[2] or (oks[1] and outs[1] != outs[2]):
            mism += 1
        if oks[0] != oks[1]:
            dis += 1
        elif oks[0] and outs[0] != outs[1]:
            mism += 1
        if oks[1]:
            okc += 1


def test_fuzz_structured() raises:
    var r = Rng(0x9E3779B97F4A7C15)
    var viol = 0
    var mism = 0
    var dis = 0
    var okc = 0
    for _ in range(6000):
        var st = gen_stream(r)
        run_one(st, viol, mism, dis, okc)
    assert_equal(viol, 0, "canary violations; ok=" + String(okc) + " dis=" + String(dis) + " mism=" + String(mism))
    assert_equal(mism, 0, "output mismatch/src-read influence; ok=" + String(okc) + " dis=" + String(dis))
    assert_equal(dis, 0, "C and Mojo disagree on acceptance")
    assert_true(okc > 300, "too few valid streams: " + String(okc))
    print("structured: ok=", okc, " C-vs-Mojo acceptance disagreements=", dis)


def test_fuzz_random_bytes() raises:
    var r = Rng(12345)
    var viol = 0
    var mism = 0
    var dis = 0
    var okc = 0
    for _ in range(3000):
        var n = r.below(60)
        var st = List[UInt8]()
        for _ in range(n): st.append(UInt8(r.below(256)))
        run_one(st, viol, mism, dis, okc)
    assert_equal(viol, 0, "canary violations random")
    assert_equal(mism, 0, "mismatch random")
    assert_equal(dis, 0, "C and Mojo disagree on acceptance (random)")
    print("random: ok=", okc, " disagreements=", dis)


def test_every_prefix_and_corruption() raises:
    var r = Rng(777)
    # 300-byte payload mixing runs, text, random
    var data = List[UInt8]()
    for i in range(300):
        var b = UInt8(97 + (i % 7))
        if i % 50 > 30: b = UInt8(r.below(256))
        if i % 97 < 20: b = 0x20
        data.append(b)
    var comp = List[UInt8](capacity=snappy_max_compressed_length(300))
    for _ in range(snappy_max_compressed_length(300)): comp.append(0)
    var cn = snappy_compress(Span(data), Span(comp))
    var valid = List[UInt8]()
    for i in range(cn): valid.append(comp[i])
    var viol = 0
    var mism = 0
    var dis = 0
    var okc = 0
    for cut in range(len(valid) + 1):
        var p = List[UInt8]()
        for i in range(cut): p.append(valid[i])
        run_one(p, viol, mism, dis, okc)
    for i in range(len(valid)):
        for _ in range(4):
            var p = valid.copy()
            p[i] = UInt8(r.below(256))
            run_one(p, viol, mism, dis, okc)
    assert_equal(viol, 0, "canary violations prefix")
    assert_equal(mism, 0, "mismatch prefix")
    assert_equal(dis, 0, "C and Mojo disagree on acceptance (prefix)")
    print("prefix/corrupt: ok=", okc, " disagreements=", dis, " len=", len(valid))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
