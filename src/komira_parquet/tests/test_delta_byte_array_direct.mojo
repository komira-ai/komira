# =============================================================================
# DELTA_LENGTH_BYTE_ARRAY and DELTA_BYTE_ARRAY.
#
# Pages are built here as the format defines them: DELTA_LENGTH_BYTE_ARRAY is
# the lengths as DELTA_BINARY_PACKED followed by the concatenated bytes;
# DELTA_BYTE_ARRAY is the prefix lengths as DELTA_BINARY_PACKED followed by
# the suffixes as DELTA_LENGTH_BYTE_ARRAY. The tests decode them and compare
# with the strings encoded, and hold the decoders to their refusals: a
# negative value count, a length that is negative or larger than the page,
# and (DELTA_BYTE_ARRAY) a NEGATIVE prefix length, which without its check
# would place the suffix before the value's start in the output buffer, and
# values that rebuild past the Int32 offset ceiling.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true

from komira_parquet.delta_byte_array import (
    decode_delta_byte_array,
    decode_delta_length_byte_array,
)


def _uleb(mut out: List[UInt8], v: Int):
    var x = UInt64(v)
    while x >= 0x80:
        out.append(UInt8((x & 0x7F) | 0x80))
        x >>= 7
    out.append(UInt8(x))


def _zz(v: Int) -> Int:
    return (v << 1) ^ (v >> 63)


def _width(v: UInt64) -> Int:
    var w = 0
    var x = v
    while x != 0:
        w += 1
        x >>= 1
    return w


def _dbp(values: List[Int], mut out: List[UInt8]):
    """Append `values` as DELTA_BINARY_PACKED (block 128, 4 miniblocks)."""
    var block_size = 128
    var mb_count = 4
    _uleb(out, block_size)
    _uleb(out, mb_count)
    _uleb(out, len(values))
    _uleb(out, _zz(values[0] if len(values) > 0 else 0))
    var mb_size = block_size // mb_count
    var i = 1
    while i < len(values):
        var end = min(i + block_size, len(values))
        var deltas = List[Int]()
        for j in range(i, end):
            deltas.append(values[j] - values[j - 1])
        var md = deltas[0]
        for j in range(len(deltas)):
            md = min(md, deltas[j])
        _uleb(out, _zz(md))
        var widths = List[Int]()
        for m in range(mb_count):
            var w = 0
            for j in range(m * mb_size, min((m + 1) * mb_size, len(deltas))):
                w = max(w, _width(UInt64(deltas[j] - md)))
            widths.append(w)
            out.append(UInt8(w))
        for m in range(mb_count):
            var w = widths[m]
            var start = len(out)
            for _ in range((mb_size * w + 7) // 8):
                out.append(UInt8(0))
            for k in range(mb_size):
                var j = m * mb_size + k
                var u = UInt64(deltas[j] - md) if j < len(deltas) else UInt64(0)
                for b in range(w):
                    if (u >> UInt64(b)) & 1 == 1:
                        var bit = k * w + b
                        out[start + (bit >> 3)] |= UInt8(1 << (bit & 7))
        i = end


def _dlba(strings: List[String]) -> List[UInt8]:
    var out = List[UInt8]()
    var lens = List[Int]()
    for i in range(len(strings)):
        lens.append(strings[i].byte_length())
    _dbp(lens, out)
    for i in range(len(strings)):
        var b = strings[i].as_bytes()
        for k in range(len(b)):
            out.append(b[k])
    return out^


def _dba(strings: List[String]) -> List[UInt8]:
    """Prefix lengths against the previous value, then the suffixes."""
    var prefixes = List[Int]()
    var suffixes = List[String]()
    var prev = String("")
    for i in range(len(strings)):
        var s = strings[i]
        var p = 0
        var sb = s.as_bytes()
        var pb = prev.as_bytes()
        while p < len(sb) and p < len(pb) and sb[p] == pb[p]:
            p += 1
        prefixes.append(p)
        suffixes.append(String(s[byte=p:]))
        prev = s
    var out = List[UInt8]()
    _dbp(prefixes, out)
    var tail = _dlba(suffixes)
    for i in range(len(tail)):
        out.append(tail[i])
    return out^


def _raw_dba(prefixes: List[Int], suffixes: List[String]) -> List[UInt8]:
    var out = List[UInt8]()
    _dbp(prefixes, out)
    var tail = _dlba(suffixes)
    for i in range(len(tail)):
        out.append(tail[i])
    return out^


def _strings() -> List[String]:
    var s: List[String] = [
        "", "a", "apple", "applesauce", "apply", "banana", "", "band",
        "bandana", "x",
    ]
    return s^


# -----------------------------------------------------------------------------
# DELTA_LENGTH_BYTE_ARRAY
# -----------------------------------------------------------------------------


def test_dlba_round_trip() raises:
    var s = _strings()
    var page = _dlba(s)
    var arr = decode_delta_length_byte_array(Span(page), len(s))
    assert_equal(arr.length, len(s))
    for i in range(len(s)):
        assert_equal(arr.get(i), s[i])


def test_dlba_zero_values_and_all_empty() raises:
    var page = _dlba(_strings())
    var none = decode_delta_length_byte_array(Span(page), 0)
    assert_equal(none.length, 0)
    var empties: List[String] = ["", "", ""]
    var p2 = _dlba(empties)
    var arr = decode_delta_length_byte_array(Span(p2), 3)
    assert_equal(arr.length, 3)
    assert_equal(arr.get_length(2), 0)


def test_dlba_refuses_a_negative_count() raises:
    var page = _dlba(_strings())
    var raised = False
    try:
        _ = decode_delta_length_byte_array(Span(page), -1)
    except e:
        raised = String(e).find("negative value count") >= 0
    assert_true(raised)


def test_dlba_refuses_negative_and_oversized_lengths() raises:
    var cases: List[Int] = [-1, 3, 1, 1000]
    for k in range(2):
        var lens: List[Int] = [cases[2 * k], cases[2 * k + 1]]
        var page = List[UInt8]()
        _dbp(lens, page)
        for _ in range(8):
            page.append(UInt8(65))
        var raised = False
        try:
            _ = decode_delta_length_byte_array(Span(page), 2)
        except e:
            raised = String(e).find("corrupt DELTA_LENGTH_BYTE_ARRAY") >= 0
        assert_true(raised, "case " + String(k))


def test_dlba_short_body_is_zero_filled() raises:
    """The lengths fit the page but the bytes after them run out: the
    missing bytes are zeros (the declared lengths are kept)."""
    var lens: List[Int] = [5, 5]
    var page = List[UInt8]()
    _dbp(lens, page)
    for _ in range(4):
        page.append(UInt8(66))
    # The lengths (10 bytes) fit the page's byte count, the body (4) does not.
    assert_true(len(page) >= 10)
    var arr = decode_delta_length_byte_array(Span(page), 2)
    assert_equal(arr.get_length(0), 5)
    assert_equal(arr.get_length(1), 5)
    var span = arr.get_span(0)
    assert_equal(Int(span[3]), 66)
    assert_equal(Int(span[4]), 0)


def test_dlba_torn_lengths_give_empty_values() raises:
    """Lengths that do not decode (a torn header) leave every value empty."""
    var torn: List[UInt8] = [0x80]
    var arr = decode_delta_length_byte_array(Span(torn), 3)
    assert_equal(arr.length, 3)
    for i in range(3):
        assert_equal(arr.get_length(i), 0)


# -----------------------------------------------------------------------------
# DELTA_BYTE_ARRAY
# -----------------------------------------------------------------------------


def test_dba_round_trip() raises:
    var s = _strings()
    var page = _dba(s)
    var arr = decode_delta_byte_array(Span(page), len(s))
    assert_equal(arr.length, len(s))
    for i in range(len(s)):
        assert_equal(arr.get(i), s[i])


def test_dba_long_values_grow_the_previous_value_buffer() raises:
    """Values longer than the 256-byte previous-value buffer, sharing long
    prefixes, still reconstruct exactly."""
    var base = String("")
    for _ in range(300):
        base += "q"
    var s: List[String] = [base, base + "r", base + "rs", String("t")]
    var page = _dba(s)
    var arr = decode_delta_byte_array(Span(page), len(s))
    for i in range(len(s)):
        assert_equal(arr.get(i), s[i])


def test_dba_prefix_longer_than_the_previous_value_is_clamped() raises:
    var prefixes: List[Int] = [0, 99, 2]
    var suffixes: List[String] = ["ab", "c", "d"]
    var page = _raw_dba(prefixes, suffixes)
    var arr = decode_delta_byte_array(Span(page), 3)
    assert_equal(arr.get(0), "ab")
    assert_equal(arr.get(1), "abc")
    assert_equal(arr.get(2), "abd")


def test_dba_refuses_a_negative_prefix_length() raises:
    """A prefix length of -3 must raise before any byte is written; without
    the check the suffix would be copied 3 bytes before the output."""
    var prefixes: List[Int] = [0, -3, 0]
    var suffixes: List[String] = ["abc", "def", "g"]
    var page = _raw_dba(prefixes, suffixes)
    var raised = False
    try:
        _ = decode_delta_byte_array(Span(page), 3)
    except e:
        raised = String(e).find("negative prefix length") >= 0
    assert_true(raised)


def _repeated_value_page(n: Int, big: Int) -> List[UInt8]:
    """One `big`-byte value, then `n - 1` values that each repeat it whole as
    their prefix with an empty suffix: a page of about `big` bytes that
    rebuilds `n * big` bytes."""
    var prefixes = List[Int](capacity=n)
    var suffixes = List[String](capacity=n)
    prefixes.append(0)
    suffixes.append(String("q") * big)
    for _ in range(1, n):
        prefixes.append(big)
        suffixes.append(String(""))
    return _raw_dba(prefixes, suffixes)


def test_dba_refuses_values_past_the_int32_offset_ceiling() raises:
    """1 MiB values: 2049 of them rebuild 2^31 + 2^20 bytes, and 2048 rebuild
    2^31, one byte past the Int32 offset ceiling. Both are refused before
    the allocation; without the check the decoder allocates 2 GiB and
    narrows the offsets past 2^31 to negative Int32s."""
    var big = 1 << 20
    var counts: List[Int] = [2049, 2048]
    for k in range(len(counts)):
        var page = _repeated_value_page(counts[k], big)
        var raised = False
        try:
            _ = decode_delta_byte_array(Span(page), counts[k])
        except e:
            raised = String(e).find("Int32 offset ceiling") >= 0
        assert_true(raised, "count " + String(counts[k]))
    # Well under the ceiling the same shape decodes: 4 copies of 1 MiB.
    var small = _repeated_value_page(4, big)
    var arr = decode_delta_byte_array(Span(small), 4)
    assert_equal(arr.length, 4)
    assert_equal(arr.get_length(3), big)


def test_dba_zero_negative_count_and_torn_prefixes() raises:
    var page = _dba(_strings())
    assert_equal(decode_delta_byte_array(Span(page), 0).length, 0)
    var raised = False
    try:
        _ = decode_delta_byte_array(Span(page), -2)
    except e:
        raised = String(e).find("negative value count") >= 0
    assert_true(raised)
    # Prefix lengths that do not decode count as 0 for every value.
    var torn: List[UInt8] = [0x80]
    var arr = decode_delta_byte_array(Span(torn), 2)
    assert_equal(arr.length, 2)
    assert_equal(arr.get_length(1), 0)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
