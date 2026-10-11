# =============================================================================
# test_tzif.mojo -- the TZif reader on files built byte by byte here
# =============================================================================
#
# `_File` writes a TZif file from parts (RFC 9636 section 3), so each test
# states the bytes it feeds and a fault is one changed field. The version 2
# files carry a version 1 block that DISAGREES with the version 2 block (a
# different offset and abbreviation), so a reader that takes the 32-bit block
# fails test_v2_block_is_the_one_read.
# =============================================================================

from std.testing import assert_equal, assert_false, assert_true

from komira_datetime import parse_tzif, seconds_from_fields


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
    # The footer agrees with the file at the last transition (2^33, 16 March
    # 2242: AAA, standard) and changes the type after it: 27 March 2242 is
    # the last Sunday of the month, so DST (CCC, +2h) starts at 02:00 UTC.
    var z = parse_tzif(
        Span(_v2(_decoy_v1(), _two_types(), "AAA0CCC-2,M3.5.0,M10.5.0/3")), "t"
    )
    assert_equal(z.footer(), "AAA0CCC-2,M3.5.0,M10.5.0/3")
    assert_equal(z.offset_at(1 << 33).abbreviation, "AAA")
    assert_equal(z.offset_at((1 << 33) + 1).abbreviation, "AAA")
    var t = z.next_transition(1 << 33)
    assert_equal(t.value().at, seconds_from_fields(2242, 3, 27, 2))
    assert_equal(t.value().before.abbreviation, "AAA")
    assert_equal(t.value().after.abbreviation, "CCC")
    assert_equal(t.value().after.utc_offset, 7200)
    assert_equal(z.offset_at(seconds_from_fields(2242, 7, 1)).abbreviation, "CCC")


def test_v1_only_file() raises:
    # The first transition is at -2^31, the earliest 32-bit time (older zic
    # wrote it as a "big bang" transition): its bytes are 80 00 00 00, so a
    # reader whose sign test misses 0x80000000 reads +2^31, after -100, and
    # refuses the file as out of order.
    var b = _Block()
    b.times.append(-(1 << 31))
    b.times.append(-100)
    b.idx.append(1)
    b.idx.append(2)
    b.offsets.append(0)
    b.dsts.append(0)
    b.abbr_idx.append(0)
    b.offsets.append(-18000)
    b.dsts.append(0)
    b.abbr_idx.append(4)
    b.offsets.append(-14400)
    b.dsts.append(1)
    b.abbr_idx.append(8)
    b.chars = _chars("LMT", "EST", "EDT")
    b.isstdcnt = 3
    b.isutcnt = 3
    var z = parse_tzif(Span(_v1_only(b)), "t")
    assert_equal(z.footer(), "")
    assert_equal(z.transition_count(), 2)
    assert_equal(z.next_transition(-(1 << 40)).value().at, -(1 << 31))
    assert_equal(z.offset_at(-(1 << 31) - 1).abbreviation, "LMT")
    assert_equal(z.offset_at(-(1 << 31)).abbreviation, "EST")
    assert_equal(z.offset_at(-(1 << 31)).utc_offset, -18000)
    assert_equal(z.offset_at(-101).abbreviation, "EST")
    assert_equal(z.offset_at(-100).abbreviation, "EDT")
    assert_equal(z.offset_at(-100).utc_offset, -14400)


def test_utc_offset_band_ends_are_read() raises:
    # -26 h and +26 h exactly are inside the band (the module header); the
    # refusals one second past each end are in test_refusals.
    var b = _two_types()
    b.offsets[0] = -26 * 3600
    b.offsets[1] = 26 * 3600
    var z = parse_tzif(Span(_v2(_decoy_v1(), b, "")), "t")
    assert_equal(z.offset_at(-1).utc_offset, -93600)
    assert_equal(z.offset_at(0).utc_offset, 93600)


def test_no_transitions_no_footer() raises:
    # A version 1 file with two types and no transition (a fixed zone):
    # every instant is in type 0 (RFC 8536 section 3.2), not the last type.
    var b = _two_types()
    b.times.clear()
    b.idx.clear()
    var z = parse_tzif(Span(_v1_only(b)), "t")
    assert_equal(z.transition_count(), 0)
    assert_equal(z.footer(), "")
    for at in [-(1 << 40), 0, 1 << 40]:
        var o = z.offset_at(at)
        assert_equal(o.abbreviation, "AAA")
        assert_equal(o.utc_offset, 0)
        assert_false(o.is_dst)
    assert_false(Bool(z.next_transition(0)))


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
    # RFC 9636 section 3.3: the footer MUST be consistent with the last
    # transition. The file's last type is AAA (+0, standard).
    _refused(
        _v2(_decoy_v1(), _two_types(), "CCC-2"),
        'TZif t: the footer "CCC-2" gives CCC (utoff 7200, isdst 0) at the'
        " last transition 8589934592; the file gives AAA (utoff 0, isdst 0)",
    )
    # Same offset and flag, another abbreviation: still another type.
    _refused(
        _v2(_decoy_v1(), _two_types(), "ZZZ0"),
        'TZif t: the footer "ZZZ0" gives ZZZ (utoff 0, isdst 0) at the'
        " last transition 8589934592; the file gives AAA (utoff 0, isdst 0)",
    )
    # Same offset and abbreviation, the other DST flag: DST all year with
    # AAA (+0) as the DST type, so the footer's type is AAA with isdst 1.
    _refused(
        _v2(_decoy_v1(), _two_types(), "XXX1AAA0,0/0,J365/25"),
        'TZif t: the footer "XXX1AAA0,0/0,J365/25" gives AAA (utoff 0, isdst'
        " 1) at the last transition 8589934592; the file gives AAA (utoff 0,"
        " isdst 0)",
    )
    # One transition (Africa/Abidjan's shape): the check still runs. The
    # only transition goes to BBB (+1h DST) at 0, so "AAA0" contradicts it.
    var one = _two_types()
    _ = one.times.pop()
    _ = one.idx.pop()
    _refused(
        _v2(_decoy_v1(), one, "AAA0"),
        'TZif t: the footer "AAA0" gives AAA (utoff 0, isdst 0) at the'
        " last transition 0; the file gives BBB (utoff 3600, isdst 1)",
    )


def main() raises:
    test_v2_block_is_the_one_read()
    test_versions_3_and_4_read_like_2()
    test_footer_after_the_last_transition()
    test_v1_only_file()
    test_utc_offset_band_ends_are_read()
    test_no_transitions_no_footer()
    test_refusals()
    print("all tzif tests passed")
