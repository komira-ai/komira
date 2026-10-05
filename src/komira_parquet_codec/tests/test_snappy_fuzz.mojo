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
# - test_fuzz_random_bytes: 3000 random streams of 0..59 bytes. Almost all
#   of them are invalid, so this mostly checks that the decoders reject the
#   same streams without writing outside the window; a floor on the accepted
#   count keeps it from passing with every stream rejected.
# - test_every_prefix_and_corruption: every prefix of a C-compressed 300-byte
#   payload and four random single-byte corruptions per position. The whole
#   stream must decode to the payload.
#
# The varint writer and the sentinel repeat test_snappy_exact_dst.mojo's:
# each test file builds as its own binary, and the package has no shared
# test-helper module.

from std.testing import TestSuite, assert_equal, assert_true

from komira_parquet_codec.snappy import (
    SnappyDecoder,
    set_snappy_decoder,
    snappy_compress,
    snappy_decompress,
    snappy_max_compressed_length,
)

comptime _SENTINEL: UInt8 = 0xCC
# Sentinel bytes on each side of the destination window, and fill bytes after
# the input. Both exceed the 15 bytes a 16-byte store can overshoot by.
comptime _GUARD = 96
# Fill bytes before the input.
comptime _LEAD = 8
# Accepted decodes the random-bytes seed gives, as measured: almost every
# random stream is invalid. Fewer means a valid stream is now rejected.
comptime _RANDOM_ACCEPTED_FLOOR = 5


struct _Rng(Movable):
    """A 64-bit LCG with an xor-shift output; fixed seeds give fixed
    streams."""

    var state: UInt64

    def __init__(out self, seed: UInt64):
        self.state = seed

    def next(mut self) -> UInt64:
        self.state = self.state * 6364136223846793005 + 1442695040888963407
        var x = self.state
        x ^= x >> 33
        return x

    def below(mut self, n: Int) -> Int:
        return Int(self.next() % UInt64(n))


struct _Tally(Movable):
    """What the decodes of one test came to, over every stream and size."""

    var clobbered: Int
    """Decodes that changed a sentinel byte outside the window."""
    var mojo_runs_differ: Int
    """Sizes at which the two Mojo runs disagreed on acceptance or output."""
    var acceptance_differs: Int
    """Sizes at which one decoder accepted and the other rejected."""
    var outputs_differ: Int
    """Sizes at which both accepted with different outputs."""
    var accepted: Int
    """Sizes at which the Mojo decoder accepted the stream."""

    def __init__(out self):
        self.clobbered = 0
        self.mojo_runs_differ = 0
        self.acceptance_differs = 0
        self.outputs_differ = 0
        self.accepted = 0

    def summary(self) -> String:
        return (
            "clobbered="
            + String(self.clobbered)
            + " mojo_runs_differ="
            + String(self.mojo_runs_differ)
            + " acceptance_differs="
            + String(self.acceptance_differs)
            + " outputs_differ="
            + String(self.outputs_differ)
            + " accepted="
            + String(self.accepted)
        )

    def assert_clean(self, what: String) raises:
        var where = what + ": " + self.summary()
        assert_equal(
            self.clobbered, 0, where + ": a decoder wrote outside its window"
        )
        assert_equal(
            self.mojo_runs_differ,
            0,
            where + ": the Mojo decoder's result depends on the bytes around"
            + " its input",
        )
        assert_equal(
            self.acceptance_differs,
            0,
            where + ": the C and Mojo decoders accept different streams",
        )
        assert_equal(
            self.outputs_differ,
            0,
            where + ": the C and Mojo decoders produce different bytes",
        )


def _put_varint(mut out: List[UInt8], v: Int):
    var x = UInt64(v)
    while x >= 128:
        out.append(UInt8((x & 127) | 128))
        x >>= 7
    out.append(UInt8(x))


def _pick_len(mut r: _Rng, hi: Int) -> Int:
    """Mostly short lengths, some up to `hi`, some around the 60-byte limit
    of a one-byte literal tag."""
    var c = r.below(10)
    if c < 7:
        return 1 + r.below(70)
    if c < 9:
        return 1 + r.below(hi)
    return 60 + r.below(8)


def _pick_offset(mut r: _Rng, produced: Int) -> Int:
    """An offset near a boundary the decoders treat specially, or one far
    past the bytes produced so far."""
    var c = r.below(14)
    if c == 0:
        return 0
    if c == 1:
        return 1
    if c == 2:
        return 2
    if c == 3:
        return 3 + r.below(5)
    if c == 4:
        return 8
    if c == 5:
        return 15 + r.below(3)
    if c == 6:
        return 31 + r.below(3)
    if c == 7:
        return 63 + r.below(3)
    if c == 8:
        return produced
    if c == 9:
        return produced + 1
    if c == 10:
        return produced - 1 if produced > 0 else 1
    if c == 11:
        return 1 + r.below(2048)
    if c == 12:
        return 1 + r.below(70000)
    return 1 + r.below(produced + 1)


def _gen_stream(mut r: _Rng) -> List[UInt8]:
    """A preamble and 1..24 tags. One literal in twelve is a byte short, one
    preamble in four does not match the tags, and one stream in fifteen is
    cut short."""
    var body = List[UInt8]()
    var produced = 0
    var ntags = 1 + r.below(24)
    for _ in range(ntags):
        var tag_type = r.below(4)
        if tag_type == 0:
            var n = _pick_len(r, 300)
            if n <= 60:
                body.append(UInt8((n - 1) << 2))
            else:
                # Literal lengths 61.. carry 1..4 length bytes; some use
                # more than they need.
                var extra = 1
                if n > 256:
                    extra = 2
                if r.below(6) == 0:
                    extra = 1 + r.below(4)
                body.append(UInt8((59 + extra) << 2))
                var m = n - 1
                for k in range(extra):
                    body.append(UInt8((m >> (8 * k)) & 255))
            var short = r.below(12) == 0
            var nbytes = n - 1 if short else n
            for _ in range(nbytes):
                body.append(UInt8(r.below(256)))
            produced += n
        elif tag_type == 1:
            var n = 4 + r.below(8)
            var offset = _pick_offset(r, produced) % 2048
            body.append(UInt8(((offset >> 8) << 5) | ((n - 4) << 2) | 1))
            body.append(UInt8(offset & 255))
            produced += n
        elif tag_type == 2:
            var n = min(_pick_len(r, 64), 64)
            var offset = _pick_offset(r, produced) % 65536
            body.append(UInt8(((n - 1) << 2) | 2))
            body.append(UInt8(offset & 255))
            body.append(UInt8(offset >> 8))
            produced += n
        else:
            var n = min(_pick_len(r, 64), 64)
            var offset = _pick_offset(r, produced)
            body.append(UInt8(((n - 1) << 2) | 3))
            for k in range(4):
                body.append(UInt8((offset >> (8 * k)) & 255))
            produced += n
    var out = List[UInt8]()
    var c = r.below(20)
    var declared = produced
    if c == 0:
        declared = produced + 1 + r.below(70)
    elif c == 1:
        declared = produced - 1 - r.below(70) if produced > 70 else 0
    elif c == 2:
        declared = 0
    elif c == 3:
        declared = 0xFFFFFFFF
    elif c == 4:
        declared = 1 << 21
    _put_varint(out, declared)
    for b in body:
        out.append(b)
    if r.below(15) == 0 and len(out) > 2:
        out.resize(len(out) - 1 - r.below(len(out) - 1), 0)
    return out^


def _declared_length(stream: List[UInt8]) -> Int:
    """The preamble's value, read from at most 5 bytes; a cut or overlong
    preamble gives whatever the bytes present add up to. Only the window
    sizes depend on it, so it need not match either decoder's parse."""
    var value = 0
    var shift = 0
    var i = 0
    while i < len(stream) and i < 5:
        value |= Int(stream[i] & 127) << shift
        shift += 7
        i += 1
        if stream[i - 1] < 128:
            break
    return value


def _decode_one(
    stream: List[UInt8], cap: Int, run: Int, mut tally: _Tally
) raises -> Optional[List[UInt8]]:
    """Decode `stream` into a `cap`-byte window: run 0 with the C library,
    runs 1 and 2 with the Mojo decoder and the input surrounded by 0xAA and
    0x55 respectively. Return the output, or None if the stream was
    rejected; a byte changed outside the window counts in `tally`."""
    var fill: UInt8 = 0x55 if run == 2 else 0xAA
    var src = List[UInt8](capacity=_LEAD + len(stream) + _GUARD)
    for _ in range(_LEAD):
        src.append(fill)
    for b in stream:
        src.append(b)
    for _ in range(_GUARD):
        src.append(fill)
    var input = Span(src)[_LEAD : _LEAD + len(stream)]

    var buf = List[UInt8](capacity=_GUARD + cap + _GUARD)
    for _ in range(_GUARD + cap + _GUARD):
        buf.append(_SENTINEL)
    var window = Span(buf)[_GUARD : _GUARD + cap]

    set_snappy_decoder(
        SnappyDecoder.C_LIBRARY if run == 0 else SnappyDecoder.MOJO
    )
    var accepted = True
    var n = 0
    try:
        n = snappy_decompress(input, window)
    except:
        accepted = False
    set_snappy_decoder(SnappyDecoder.C_LIBRARY)

    for k in range(_GUARD):
        if buf[k] != _SENTINEL or buf[_GUARD + cap + k] != _SENTINEL:
            tally.clobbered += 1
            break
    if not accepted:
        return None
    var out = List[UInt8](capacity=n)
    for k in range(n):
        out.append(buf[_GUARD + k])
    return out^


def _check_stream(stream: List[UInt8], mut tally: _Tally) raises:
    """Decode `stream` at each window size with all three runs and count
    every way the results disagree."""
    var declared = _declared_length(stream)
    # A preamble too large to allocate for gets windows near an arbitrary
    # 100 bytes; both decoders must refuse it before writing.
    var base = declared if declared <= (1 << 20) else 100
    var caps: List[Int] = [base, base + 1, base + 63, base + 64, base + 65]
    if base > 0:
        caps.append(base - 1)
    for cap in caps:
        var c_out = _decode_one(stream, cap, 0, tally)
        var mojo_out = _decode_one(stream, cap, 1, tally)
        var mojo_out_other_fill = _decode_one(stream, cap, 2, tally)
        if Bool(mojo_out) != Bool(mojo_out_other_fill) or (
            mojo_out and mojo_out.value() != mojo_out_other_fill.value()
        ):
            tally.mojo_runs_differ += 1
        if Bool(c_out) != Bool(mojo_out):
            tally.acceptance_differs += 1
        elif c_out and c_out.value() != mojo_out.value():
            tally.outputs_differ += 1
        if mojo_out:
            tally.accepted += 1


def test_fuzz_structured() raises:
    var r = _Rng(0x9E3779B97F4A7C15)
    var tally = _Tally()
    for _ in range(6000):
        _check_stream(_gen_stream(r), tally)
    tally.assert_clean("structured")
    assert_true(
        tally.accepted > 300,
        "structured: too few streams accepted, " + tally.summary(),
    )


def test_fuzz_random_bytes() raises:
    var r = _Rng(12345)
    var tally = _Tally()
    for _ in range(3000):
        var n = r.below(60)
        var stream = List[UInt8](capacity=n)
        for _ in range(n):
            stream.append(UInt8(r.below(256)))
        _check_stream(stream, tally)
    tally.assert_clean("random bytes")
    assert_true(
        tally.accepted >= _RANDOM_ACCEPTED_FLOOR,
        "random bytes: too few streams accepted, " + tally.summary(),
    )


def test_every_prefix_and_corruption() raises:
    var r = _Rng(777)
    # A 300-byte payload of short repeats, spaces and random bytes, so the
    # compressed stream has literals and copies of each kind.
    var data = List[UInt8](capacity=300)
    for i in range(300):
        var b = UInt8(97 + (i % 7))
        if i % 50 > 30:
            b = UInt8(r.below(256))
        if i % 97 < 20:
            b = 0x20
        data.append(b)
    var bound = snappy_max_compressed_length(len(data))
    var compressed = List[UInt8](capacity=bound)
    for _ in range(bound):
        compressed.append(0)
    var written = snappy_compress(Span(data), Span(compressed))
    assert_true(written > 0, "the C compressor wrote nothing")
    compressed.resize(written, 0)

    # The whole stream decodes to the payload at the five sizes that fit
    # it, and is refused at the one that does not.
    var whole = _Tally()
    _check_stream(compressed, whole)
    whole.assert_clean("whole stream")
    assert_equal(whole.accepted, 5, "whole stream: " + whole.summary())
    var decoded = _decode_one(compressed, len(data), 1, whole)
    assert_true(Bool(decoded), "whole stream: the Mojo decoder rejected it")
    assert_true(
        decoded.value() == data, "whole stream: decodes to other bytes"
    )

    var tally = _Tally()
    for cut in range(len(compressed) + 1):
        var prefix = List[UInt8](capacity=cut)
        for i in range(cut):
            prefix.append(compressed[i])
        _check_stream(prefix, tally)
    for i in range(len(compressed)):
        for _ in range(4):
            var corrupted = compressed.copy()
            corrupted[i] = UInt8(r.below(256))
            _check_stream(corrupted, tally)
    tally.assert_clean("prefixes and corruptions")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
