# =============================================================================
# test_utf8.mojo -- utf8_invalid_at and string_from_utf8 against RFC 3629.
# =============================================================================
#
# The oracle (`_oracle_bad_at`) is written from RFC 3629 §3 and §4 in a
# different form from the code under test: it decodes the scalar value from
# the bit patterns (0xxxxxxx, 110xxxxx 10xxxxxx, ...) and then refuses an
# overlong form (a scalar below 0x80, 0x800 or 0x10000 for its length), a
# surrogate (U+D800..U+DFFF) and anything above U+10FFFF. The code under test
# instead keeps a table of lead octets and the allowed range of the second.
#
# What each test proves (and the defect it catches):
#   two_octet_grid        every lead octet 0x00..0xFF followed by every
#                         second octet 0x00..0xFF (and enough continuation
#                         octets to finish any sequence), behind an ASCII
#                         prefix of 0, 1 and 2 octets: the offset is exactly
#                         the oracle's. Catches a moved lead-class bound
#                         (0xC2, 0xDF, 0xE1, 0xEC, 0xEE, 0xEF, 0xF1, 0xF3), a
#                         wrong second-octet range (0xE0's 0xA0, 0xED's 0x9F,
#                         0xF0's 0x90, 0xF4's 0x8F, the default 0x80..0xBF),
#                         a wrong `need`, and an offset that is not the lead's.
#   later_continuations   the third and fourth octets of 3- and 4-octet
#                         sequences at 0x00, 0x7F, 0x80, 0xBF, 0xC0, 0xFF:
#                         the `bk < 0x80` / `bk > 0xBF` bounds and the
#                         `range(2, need + 1)` loop (a loop that skips the
#                         third or the last octet).
#   truncated_sequences   a lead with 0..need-1 of its continuation octets at
#                         the end of the data is refused at the lead; the
#                         data is a prefix of a buffer that holds the rest of
#                         a valid sequence, so a bound that reads one octet
#                         past the end (`i + need > n`) sees that octet and
#                         goes wrong deterministically.
#   stride                valid 1- to 4-octet sequences in a row, then an
#                         ill-formed octet: the offset proves each sequence
#                         advanced by its own length (`i += need`).
#   string_from_utf8      the empty input, ASCII and multi-octet text come
#                         back as the same String; an ill-formed input raises
#                         `invalid UTF-8 at octet <k>` with k = 0 (the
#                         `bad > 0` mutant), a middle and the last octet.
# =============================================================================

from std.testing import assert_equal

from komira_content_line import string_from_utf8, utf8_invalid_at


def _oracle_bad_at(d: List[UInt8]) -> Int:
    """RFC 3629 by decoding: the offset of the first ill-formed sequence's
    lead octet, or -1."""
    var i = 0
    var n = len(d)
    while i < n:
        var b0 = Int(d[i])
        var length: Int
        var cp: Int
        if (b0 & 0x80) == 0:
            i += 1
            continue
        elif (b0 & 0xE0) == 0xC0:
            length = 2
            cp = b0 & 0x1F
        elif (b0 & 0xF0) == 0xE0:
            length = 3
            cp = b0 & 0x0F
        elif (b0 & 0xF8) == 0xF0:
            length = 4
            cp = b0 & 0x07
        else:
            return i
        if i + length > n:
            return i
        for k in range(1, length):
            var c = Int(d[i + k])
            if (c & 0xC0) != 0x80:
                return i
            cp = (cp << 6) | (c & 0x3F)
        var least = 0x80
        if length == 3:
            least = 0x800
        elif length == 4:
            least = 0x10000
        if cp < least or (cp >= 0xD800 and cp <= 0xDFFF) or cp > 0x10FFFF:
            return i
        i += length
    return -1


def _ascii(n: Int) -> List[UInt8]:
    var out = List[UInt8]()
    for k in range(n):
        out.append(UInt8(97 + k))
    return out^


def test_two_octet_grid() raises:
    var checked = 0
    var well_formed = 0
    var at_lead = 0
    for pre in range(3):
        for b0 in range(256):
            for b1 in range(256):
                var d = _ascii(pre)
                d.append(UInt8(b0))
                d.append(UInt8(b1))
                d.append(0x80)
                d.append(0x80)
                d.append(0x41)
                var want = _oracle_bad_at(d)
                var got = utf8_invalid_at(Span(d))
                if got != want:
                    assert_equal(
                        String(got),
                        String(want),
                        String("prefix ")
                        + String(pre)
                        + String(" lead ")
                        + hex(b0)
                        + String(" second ")
                        + hex(b1),
                    )
                if want == -1:
                    well_formed += 1
                elif want == pre:
                    at_lead += 1
                checked += 1
    assert_equal(checked, 3 * 65536)
    # The oracle is not vacuous. Per prefix, the well-formed inputs are a
    # 4-octet lead with a valid second octet (F0: 48, F1..F3: 3 * 64, F4: 16
    # = 256), whose 80 80 completes it, and an ASCII octet before a 3-octet
    # lead other than E0 (E1..EF: 15 * 128 = 1920), which 80 80 completes:
    # 2176. Refused at the lead: 29632 (counted with a reference decoder).
    assert_equal(well_formed, 3 * 2176)
    assert_equal(at_lead, 3 * 29632)
    print("  test_two_octet_grid PASS")


def _seq(lead: Int, second: Int, third: Int, fourth: Int, length: Int) -> List[UInt8]:
    var d = List[UInt8]()
    d.append(UInt8(lead))
    d.append(UInt8(second))
    if length >= 3:
        d.append(UInt8(third))
    if length >= 4:
        d.append(UInt8(fourth))
    return d^


def test_later_continuations() raises:
    var values = List[Int]()
    values.append(0x00)
    values.append(0x7F)
    values.append(0x80)
    values.append(0xBF)
    values.append(0xC0)
    values.append(0xFF)
    # (lead, a second octet that is valid for it, length)
    var leads = List[Int]()
    var seconds = List[Int]()
    var lengths = List[Int]()
    leads.append(0xE0); seconds.append(0xA0); lengths.append(3)
    leads.append(0xE1); seconds.append(0x80); lengths.append(3)
    leads.append(0xED); seconds.append(0x9F); lengths.append(3)
    leads.append(0xEF); seconds.append(0xBF); lengths.append(3)
    leads.append(0xF0); seconds.append(0x90); lengths.append(4)
    leads.append(0xF2); seconds.append(0x80); lengths.append(4)
    leads.append(0xF4); seconds.append(0x8F); lengths.append(4)
    for li in range(len(leads)):
        for pos in range(2, lengths[li]):
            for vi in range(len(values)):
                var v = values[vi]
                var third = 0x80
                var fourth = 0x80
                if pos == 2:
                    third = v
                else:
                    fourth = v
                for pre in range(3):
                    var d = _ascii(pre)
                    d.extend(_seq(leads[li], seconds[li], third, fourth, lengths[li]))
                    d.append(0x41)
                    var want = -1
                    if v < 0x80 or v > 0xBF:
                        want = pre
                    assert_equal(_oracle_bad_at(d), want)
                    assert_equal(
                        utf8_invalid_at(Span(d)),
                        want,
                        String("lead ")
                        + hex(leads[li])
                        + String(" octet ")
                        + String(pos)
                        + String(" = ")
                        + hex(v),
                    )
    print("  test_later_continuations PASS")


def test_truncated_sequences() raises:
    # Each full sequence is valid; every proper prefix of it that keeps the
    # lead is refused at the lead, even though the octets after the span in
    # the same buffer would complete it.
    var full = List[List[UInt8]]()
    full.append(_seq(0xC3, 0xA9, 0, 0, 2))
    full.append(_seq(0xE0, 0xA0, 0x80, 0, 3))
    full.append(_seq(0xE2, 0x82, 0xAC, 0, 3))
    full.append(_seq(0xF0, 0x9F, 0x98, 0x80, 4))
    full.append(_seq(0xF4, 0x8F, 0xBF, 0xBF, 4))
    for fi in range(len(full)):
        for pre in range(3):
            var buf = _ascii(pre)
            buf.extend(full[fi].copy())
            assert_equal(utf8_invalid_at(Span(buf)), -1)
            for keep in range(1, len(full[fi])):
                var end = pre + keep
                assert_equal(
                    utf8_invalid_at(Span(buf)[0:end]),
                    pre,
                    String("sequence ")
                    + String(fi)
                    + String(" cut after ")
                    + String(keep)
                    + String(" octets"),
                )
    # Nothing at all and only ASCII are well formed.
    var empty = List[UInt8]()
    assert_equal(utf8_invalid_at(Span(empty)), -1)
    assert_equal(utf8_invalid_at(Span(_ascii(3))), -1)
    print("  test_truncated_sequences PASS")


def test_stride() raises:
    # "a" (1) + U+00E9 (2) + U+20AC (3) + U+1F600 (4) = 10 octets, then 0xFF.
    var d = List[UInt8]()
    d.append(0x61)
    d.extend(_seq(0xC3, 0xA9, 0, 0, 2))
    d.extend(_seq(0xE2, 0x82, 0xAC, 0, 3))
    d.extend(_seq(0xF0, 0x9F, 0x98, 0x80, 4))
    assert_equal(utf8_invalid_at(Span(d)), -1)
    d.append(0xFF)
    assert_equal(utf8_invalid_at(Span(d)), 10)
    # The same with the longest sequence first: 4 + 3 + 2 + 1, then a bare
    # continuation octet.
    var r = List[UInt8]()
    r.extend(_seq(0xF0, 0x9F, 0x98, 0x80, 4))
    r.extend(_seq(0xE2, 0x82, 0xAC, 0, 3))
    r.extend(_seq(0xC3, 0xA9, 0, 0, 2))
    r.append(0x61)
    r.append(0x80)
    assert_equal(utf8_invalid_at(Span(r)), 10)
    print("  test_stride PASS")


def _from_err(d: List[UInt8]) -> String:
    try:
        _ = string_from_utf8(Span(d))
    except e:
        return String(e)
    return String("no error")


def test_string_from_utf8() raises:
    var empty = List[UInt8]()
    assert_equal(string_from_utf8(Span(empty)), "")
    assert_equal(string_from_utf8("FN:Jane".as_bytes()), "FN:Jane")
    var s = String("André € \U0001F600")
    var got = string_from_utf8(s.as_bytes())
    assert_equal(got, s)
    assert_equal(got.byte_length(), 15)
    var first = List[UInt8]()
    first.append(0x80)
    first.append(0x61)
    assert_equal(_from_err(first), "invalid UTF-8 at octet 0")
    var mid = _ascii(2)
    mid.append(0xC0)
    mid.append(0xAF)
    mid.append(0x61)
    assert_equal(_from_err(mid), "invalid UTF-8 at octet 2")
    var last = _ascii(3)
    last.append(0xE2)
    last.append(0x82)
    assert_equal(_from_err(last), "invalid UTF-8 at octet 3")
    print("  test_string_from_utf8 PASS")


def main() raises:
    print("test_utf8")
    test_two_octet_grid()
    test_later_continuations()
    test_truncated_sequences()
    test_stride()
    test_string_from_utf8()
    print("ALL TESTS PASS")
