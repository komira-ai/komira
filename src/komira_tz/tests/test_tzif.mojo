# =============================================================================
# test_tzif.mojo -- the TZif reader on files built byte by byte here
# =============================================================================
#
# `_File` writes a TZif file from parts (RFC 8536 section 3), so each test
# states the bytes it feeds and a fault is one changed field. The version 2
# files carry a version 1 block that DISAGREES with the version 2 block (a
# different offset and abbreviation), so a reader that takes the 32-bit block
# fails test_v2_block_is_the_one_read.
# =============================================================================

from std.testing import assert_equal, assert_false, assert_true

from komira_tz import parse_tzif


struct _Block(Copyable, Movable):
    var times: List[Int]
    var idx: List[Int]
    var offsets: List[Int]
    var dsts: List[Int]
    var abbr_idx: List[Int]
    var chars: List[UInt8]  # the abbreviations, each NUL-terminated
    var isutcnt: Int
    var isstdcnt: Int
    var leapcnt: Int

    def __init__(out self):
        self.times = List[Int]()
        self.idx = List[Int]()
        self.offsets = List[Int]()
        self.dsts = List[Int]()
        self.abbr_idx = List[Int]()
        self.chars = List[UInt8]()
        self.isutcnt = 0
        self.isstdcnt = 0
        self.leapcnt = 0


def _chars(*names: String) -> List[UInt8]:
    var out = List[UInt8]()
    for n in names:
        for c in n.as_bytes():
            out.append(c)
        out.append(0)
    return out^


def _be(mut out: List[UInt8], v: Int, size: Int):
    for k in range(size):
        out.append(UInt8((v >> ((size - 1 - k) * 8)) & 0xFF))


def _header(mut out: List[UInt8], version: Int, b: _Block):
    for c in "TZif".as_bytes():
        out.append(c)
    out.append(UInt8(version))
    for _ in range(15):
        out.append(0)
    _be(out, b.isutcnt, 4)
    _be(out, b.isstdcnt, 4)
    _be(out, b.leapcnt, 4)
    _be(out, len(b.times), 4)
    _be(out, len(b.offsets), 4)
    _be(out, len(b.chars), 4)


def _body(mut out: List[UInt8], b: _Block, time_size: Int):
    for i in range(len(b.times)):
        _be(out, b.times[i], time_size)
    for i in range(len(b.idx)):
        out.append(UInt8(b.idx[i]))
    for i in range(len(b.offsets)):
        _be(out, b.offsets[i], 4)
        out.append(UInt8(b.dsts[i]))
        out.append(UInt8(b.abbr_idx[i]))
    for i in range(len(b.chars)):
        out.append(b.chars[i])
    for _ in range(b.leapcnt):
        _be(out, 0, time_size + 4)
    for _ in range(b.isstdcnt):
        out.append(0)
    for _ in range(b.isutcnt):
        out.append(0)


def _v1_only(b: _Block) -> List[UInt8]:
    var out = List[UInt8]()
    _header(out, 0, b)
    _body(out, b, 4)
    return out^


def _v2(v1: _Block, v2: _Block, footer: String, version: Int = 0x32) -> List[UInt8]:
    var out = List[UInt8]()
    _header(out, version, v1)
    _body(out, v1, 4)
    _header(out, version, v2)
    _body(out, v2, 8)
    out.append(0x0A)
    for c in footer.as_bytes():
        out.append(c)
    out.append(0x0A)
    return out^


def _decoy_v1() -> _Block:
    """A version 1 block that disagrees with every version 2 block here."""
    var b = _Block()
    b.offsets.append(7200)
    b.dsts.append(0)
    b.abbr_idx.append(0)
    b.chars = _chars("XXX")
    return b^


def _two_types() -> _Block:
    """Type 0 is AAA at +0, type 1 BBB at +1h DST; transitions at 0 (to BBB)
    and at 2^33 (to AAA: past 2038, so only a 64-bit read has it)."""
    var b = _Block()
    b.times.append(0)
    b.times.append(1 << 33)
    b.idx.append(1)
    b.idx.append(0)
    b.offsets.append(0)
    b.dsts.append(0)
    b.abbr_idx.append(0)
    b.offsets.append(3600)
    b.dsts.append(1)
    b.abbr_idx.append(4)
    b.chars = _chars("AAA", "BBB")
    return b^


def _refused(data: List[UInt8], message: String) raises:
    var got = String()
    try:
        _ = parse_tzif(Span(data), "t")
    except e:
        got = String(e)
    assert_equal(got, message)


def test_v2_block_is_the_one_read() raises:
    var z = parse_tzif(Span(_v2(_decoy_v1(), _two_types(), "")), "t")
    assert_equal(z.name, "t")
    assert_equal(z.transition_count(), 2)
    assert_equal(z.footer(), "")
    # Before the first transition: type 0 (RFC 8536 section 3.2).
    assert_equal(z.offset_at(-1).abbreviation, "AAA")
    assert_equal(z.offset_at(-1).utc_offset, 0)
    # From the transition instant itself on: the type it starts.
    assert_equal(z.offset_at(0).abbreviation, "BBB")
    assert_true(z.offset_at(0).is_dst)
    assert_equal(z.offset_at(0).utc_offset, 3600)
    assert_equal(z.offset_at((1 << 33) - 1).abbreviation, "BBB")
    assert_equal(z.offset_at(1 << 33).abbreviation, "AAA")
    # No footer: the last type holds for ever.
    assert_equal(z.offset_at(1 << 40).abbreviation, "AAA")
    var t = z.next_transition(-100)
    assert_equal(t.value().at, 0)
    assert_equal(t.value().before.abbreviation, "AAA")
    assert_equal(t.value().after.abbreviation, "BBB")
    assert_equal(z.next_transition(0).value().at, 1 << 33)
    assert_false(Bool(z.next_transition(1 << 33)))


def test_versions_3_and_4_read_like_2() raises:
    for v in range(0x33, 0x35):
        var z = parse_tzif(Span(_v2(_decoy_v1(), _two_types(), "", v)), "t")
        assert_equal(z.offset_at(0).abbreviation, "BBB")


def test_footer_after_the_last_transition() raises:
    var z = parse_tzif(Span(_v2(_decoy_v1(), _two_types(), "CCC-2")), "t")
    assert_equal(z.footer(), "CCC-2")
    # At the last transition the file's type; after it the footer's.
    assert_equal(z.offset_at(1 << 33).abbreviation, "AAA")
    assert_equal(z.offset_at((1 << 33) + 1).abbreviation, "CCC")
    assert_equal(z.offset_at((1 << 33) + 1).utc_offset, 7200)


def test_v1_only_file() raises:
    var b = _Block()
    b.times.append(-100)
    b.idx.append(1)
    b.offsets.append(0)
    b.dsts.append(0)
    b.abbr_idx.append(0)
    b.offsets.append(-18000)
    b.dsts.append(0)
    b.abbr_idx.append(4)
    b.chars = _chars("LMT", "EST")
    b.isstdcnt = 2
    b.isutcnt = 2
    var z = parse_tzif(Span(_v1_only(b)), "t")
    assert_equal(z.footer(), "")
    assert_equal(z.offset_at(-101).abbreviation, "LMT")
    assert_equal(z.offset_at(-100).utc_offset, -18000)


def test_refusals() raises:
    var good = _v2(_decoy_v1(), _two_types(), "")
    var short = List[UInt8]()
    for i in range(10):
        short.append(good[i])
    _refused(short, "TZif t: truncated: a header needs 44 bytes, the file has 10")

    var magic = good.copy()
    magic[3] = UInt8(ord("g"))
    _refused(magic, "TZif t: no TZif magic at byte 0")

    var version = good.copy()
    version[4] = 0x35
    _refused(version, "TZif t: unknown version byte 53")

    # The second header starts after 44 + the decoy block (10 bytes).
    var second = good.copy()
    second[44 + 10 + 4] = 0x33
    _refused(second, "TZif t: the second header's version 3 is not the first's 2")

    var cut = good.copy()
    _ = cut.pop()
    _ = cut.pop()
    _ = cut.pop()
    _ = cut.pop()
    _refused(cut, "TZif t: truncated: the data block needs 136 bytes, the file has 134")

    var no_types = _Block()
    no_types.chars = _chars("A")
    _refused(_v1_only(no_types), "TZif t: typecnt is 0")

    var no_chars = _decoy_v1()
    no_chars.chars = List[UInt8]()
    _refused(_v1_only(no_chars), "TZif t: charcnt is 0")

    var isut = _decoy_v1()
    isut.isutcnt = 2
    _refused(_v1_only(isut), "TZif t: isutcnt is neither 0 nor typecnt")

    var isstd = _decoy_v1()
    isstd.isstdcnt = 3
    _refused(_v1_only(isstd), "TZif t: isstdcnt is neither 0 nor typecnt")

    var leap = _decoy_v1()
    leap.leapcnt = 1
    _refused(
        _v1_only(leap),
        "TZif t: leap-second records are not supported (the zone counts TAI seconds)",
    )

    var order = _two_types()
    order.times[1] = 0
    _refused(_v2(_decoy_v1(), order, ""), "TZif t: transition 1 is not after transition 0")

    var index = _two_types()
    index.idx[0] = 2
    _refused(_v2(_decoy_v1(), index, ""), "TZif t: transition 0 names type 2, past typecnt 2")

    var dst = _two_types()
    dst.dsts[1] = 2
    _refused(_v2(_decoy_v1(), dst, ""), "TZif t: type 1 has isdst 2")

    var far = _two_types()
    far.offsets[0] = 26 * 3600 + 1
    _refused(
        _v2(_decoy_v1(), far, ""),
        "TZif t: type 0 has UTC offset 93601, outside -26..+26 hours",
    )
    var far_west = _two_types()
    far_west.offsets[0] = -26 * 3600 - 1
    _refused(
        _v2(_decoy_v1(), far_west, ""),
        "TZif t: type 0 has UTC offset -93601, outside -26..+26 hours",
    )

    var past = _two_types()
    past.abbr_idx[1] = 8
    _refused(_v2(_decoy_v1(), past, ""), "TZif t: abbreviation index 8 is past charcnt 8")

    var no_nul = _two_types()
    no_nul.chars = _chars("AAA")
    for c in "BBBB".as_bytes():
        no_nul.chars.append(c)
    _refused(_v2(_decoy_v1(), no_nul, ""), "TZif t: abbreviation at index 4 has no NUL")

    var space = _two_types()
    space.chars = _chars("AAA", "B B")
    _refused(
        _v2(_decoy_v1(), space, ""),
        "TZif t: abbreviation byte 32 is not a letter, digit, + or -",
    )

    var no_open = good.copy()
    no_open[len(no_open) - 2] = UInt8(ord("x"))
    _refused(no_open, "TZif t: no newline opens the footer at byte 136")

    var no_close = good.copy()
    _ = no_close.pop()
    no_close.append(UInt8(ord("x")))
    _refused(no_close, "TZif t: no newline closes the footer")

    var trailing = good.copy()
    trailing.append(0)
    _refused(trailing, "TZif t: 1 bytes follow the footer")

    var v1_trailing = _v1_only(_decoy_v1())
    v1_trailing.append(0)
    _refused(v1_trailing, "TZif t: 1 bytes follow the version 1 data block")

    _refused(
        _v2(_decoy_v1(), _two_types(), "EST"),
        'POSIX TZ string "EST": standard offset: expected a digit at byte 3',
    )
    _refused(
        _v2(_decoy_v1(), _two_types(), "EST\t5"),
        "TZif t: footer byte 9 is not printable ASCII",
    )


def main() raises:
    test_v2_block_is_the_one_read()
    test_versions_3_and_4_read_like_2()
    test_footer_after_the_last_transition()
    test_v1_only_file()
    test_refusals()
    print("all tzif tests passed")
