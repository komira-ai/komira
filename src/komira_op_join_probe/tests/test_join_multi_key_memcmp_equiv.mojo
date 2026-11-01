# `_string_bytes_equal`, the byte equality of every string-keyed composite
# probe, against a byte-at-a-time reference and an independent oracle: equal
# and unequal strings at word boundaries, a difference at every position of
# every length to 80, embedded NUL and high bytes, and
# the composite join's answers over string keys.

from std.testing import TestSuite, assert_equal, assert_true, assert_false
from std.sys import size_of

from komira_arrow.column import Column
from komira_arrow.arrow_types import ArrowType
from komira_arrow.bitmap import Bitmap
from komira_buffer.owned_aligned_buffer import OwnedAlignedBuffer
from komira_arrow.record_batch import RecordBatch, RecordBatchBuilder
from komira_arrow.schema import Field, Schema, SchemaBuilder
from komira_arrow.string_array import StringArray
from komira_buffer.heap_region import HeapRegion

from komira_op_join_probe.join_multi_key import (
    _string_bytes_equal,
)
from komira_op_join_probe.join_key_extract import (
    extract_join_key_columns_serial,
)
from komira_op_join_probe.join_multi_key_builder import (
    MultiKeyHashJoinBuilder,
)


@always_inline
def _ref_byte_walk[
    oa_off: Origin[mut=False], oa_data: Origin[mut=False],
    ob_off: Origin[mut=False], ob_data: Origin[mut=False],
](
    a_offsets: UnsafePointer[Scalar[DType.int32], oa_off],
    a_data: UnsafePointer[Scalar[DType.uint8], oa_data],
    a_idx: Int,
    b_offsets: UnsafePointer[Scalar[DType.int32], ob_off],
    b_data: UnsafePointer[Scalar[DType.uint8], ob_data],
    b_idx: Int,
) -> Bool:
    """Byte-at-a-time equality, the reference `_string_bytes_equal` is checked
    against (both are also checked against an oracle independent of both).
    """
    var a_start = Int((a_offsets + a_idx)[])
    var a_end = Int((a_offsets + a_idx + 1)[])
    var b_start = Int((b_offsets + b_idx)[])
    var b_end = Int((b_offsets + b_idx + 1)[])
    var a_len = a_end - a_start
    var b_len = b_end - b_start
    if a_len != b_len:
        return False
    var i = 0
    while i < a_len:
        if (a_data + a_start + i)[] != (b_data + b_start + i)[]:
            return False
        i += 1
    return True


def _make_string_array_from_bytes(
    vals: List[List[UInt8]],
) raises -> StringArray[HeapRegion]:
    """Build a non-null StringArray whose slot i holds exactly `vals[i]`."""
    var n = len(vals)
    var total = 0
    for i in range(n):
        total += len(vals[i])

    comptime int32_size = size_of[Int32]()
    var offsets_buf = OwnedAlignedBuffer((n + 1) * int32_size)
    offsets_buf.set_typed[Int32](0, Int32(0))
    var data_buf = OwnedAlignedBuffer(total if total > 0 else 1)

    var off = 0
    var bm = Bitmap.create(n)
    for i in range(n):
        bm.set(i)
        ref v = vals[i]
        for j in range(len(v)):
            data_buf.set_typed[UInt8](off + j, v[j])
        off += len(v)
        offsets_buf.set_typed[Int32](i + 1, Int32(off))

    offsets_buf.set_length(Int64((n + 1) * int32_size))
    data_buf.set_length(Int64(total))

    return StringArray[HeapRegion](
        offsets=offsets_buf^,
        data=data_buf^,
        validity=bm^,
        length=n,
        data_length=total,
        null_count=0,
    )


def _bytes(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    var p = s.unsafe_ptr().bitcast[UInt8]()
    for i in range(s.byte_length()):
        out.append((p + i)[])
    return out^


def _cat(a: List[UInt8], b: List[UInt8]) -> List[UInt8]:
    var out = List[UInt8]()
    for i in range(len(a)):
        out.append(a[i])
    for i in range(len(b)):
        out.append(b[i])
    return out^


def _fill(byte: UInt8, n: Int) -> List[UInt8]:
    var out = List[UInt8]()
    for _ in range(n):
        out.append(byte)
    return out^


def _oracle_equal(a: List[UInt8], b: List[UInt8]) -> Bool:
    if len(a) != len(b):
        return False
    for i in range(len(a)):
        if a[i] != b[i]:
            return False
    return True


def _hex(v: List[UInt8]) -> String:
    comptime digits = String("0123456789abcdef")
    var out = String("")
    for i in range(len(v)):
        out += digits[byte=Int(v[i]) >> 4]
        out += digits[byte=Int(v[i]) & 0xF]
    return out^


def _assert_matrix(
    a_vals: List[List[UInt8]],
    b_vals: List[List[UInt8]],
    label: String,
) raises:
    var sa = _make_string_array_from_bytes(a_vals)
    var sb = _make_string_array_from_bytes(b_vals)

    var a_off_view = sa.offsets.view_ro()
    var a_off = a_off_view._unsafe_ptr().bitcast[Scalar[DType.int32]]()
    var a_dat_view = sa.data.view_ro()
    var a_dat = a_dat_view._unsafe_ptr().bitcast[Scalar[DType.uint8]]()
    var b_off_view = sb.offsets.view_ro()
    var b_off = b_off_view._unsafe_ptr().bitcast[Scalar[DType.int32]]()
    var b_dat_view = sb.data.view_ro()
    var b_dat = b_dat_view._unsafe_ptr().bitcast[Scalar[DType.uint8]]()

    var pairs = 0
    for i in range(len(a_vals)):
        for j in range(len(b_vals)):
            var want = _oracle_equal(a_vals[i], b_vals[j])
            var got_prod = _string_bytes_equal(
                a_off, a_dat, i, b_off, b_dat, j
            )
            var got_ref = _ref_byte_walk(a_off, a_dat, i, b_off, b_dat, j)
            var ctx = (
                label
                + " pair(a["
                + String(i)
                + "]="
                + _hex(a_vals[i])
                + ", b["
                + String(j)
                + "]="
                + _hex(b_vals[j])
                + ")"
            )
            assert_equal(
                got_prod,
                want,
                "PRODUCTION kernel disagrees with the oracle: " + ctx,
            )
            assert_equal(
                got_ref,
                want,
                "REFERENCE byte walk disagrees with the oracle: " + ctx,
            )
            pairs += 1

    _ = sa.offsets
    _ = sa.data
    _ = sb.offsets
    _ = sb.data
    assert_true(pairs == len(a_vals) * len(b_vals))


def test_embedded_nul_bytes() raises:
    """A NUL inside the key must NOT terminate the compare."""
    var vals = List[List[UInt8]]()
    vals.append(_cat(_bytes("ab"), _cat(_fill(0, 1), _bytes("cd"))))
    vals.append(_cat(_bytes("ab"), _cat(_fill(0, 1), _bytes("ce"))))
    vals.append(_cat(_bytes("ab"), _cat(_fill(0, 1), _bytes("cd"))))
    vals.append(_cat(_bytes("ab"), _cat(_fill(0, 2), _bytes("cd"))))
    vals.append(_cat(_fill(0, 1), _bytes("abcd")))
    vals.append(_fill(0, 5))
    vals.append(_fill(0, 6))
    _assert_matrix(vals, vals, "embedded-nul")


def test_high_bytes_no_sign_confusion() raises:
    """0x80 / 0xFF must compare as UNSIGNED bytes."""
    var vals = List[List[UInt8]]()
    vals.append(_fill(0x00, 8))
    vals.append(_fill(0x01, 8))
    vals.append(_fill(0x7F, 8))
    vals.append(_fill(0x80, 8))
    vals.append(_fill(0xFF, 8))
    vals.append(_cat(_fill(0xFF, 7), _fill(0xFE, 1)))
    vals.append(_cat(_fill(0x00, 7), _fill(0x80, 1)))
    vals.append(_cat(_fill(0x80, 7), _fill(0x00, 1)))
    _assert_matrix(vals, vals, "high-bytes")


def test_prefix_of_pairs_and_empty() raises:
    """Length mismatch must be UNEQUAL even when one side is a prefix."""
    var vals = List[List[UInt8]]()
    vals.append(List[UInt8]())  # empty
    vals.append(_bytes("a"))
    vals.append(_bytes("ab"))
    vals.append(_bytes("abc"))
    vals.append(_bytes("abcdefgh"))
    vals.append(_bytes("abcdefghi"))
    vals.append(_bytes("abcdefg"))
    _assert_matrix(vals, vals, "prefix-of")

    var only_empty = List[List[UInt8]]()
    only_empty.append(List[UInt8]())
    only_empty.append(List[UInt8]())
    _assert_matrix(only_empty, only_empty, "empty-only")


def test_word_boundary_lengths() raises:
    """Lengths straddling 8 / 16 / 32 / 64-byte boundaries, each differing
    ONLY in the final byte — the position a truncating compare drops.
    """
    var lens: List[Int] = [1, 7, 8, 9, 15, 16, 17, 31, 32, 33, 63, 64, 65]
    var vals = List[List[UInt8]]()
    for li in range(len(lens)):
        var n = lens[li]
        vals.append(_fill(0x61, n))  # 'a' * n
        var tail_diff = _fill(0x61, n)
        tail_diff[n - 1] = 0x62  # last byte 'b'
        vals.append(tail_diff^)
        var head_diff = _fill(0x61, n)
        head_diff[0] = 0x62  # first byte 'b'
        vals.append(head_diff^)
    _assert_matrix(vals, vals, "word-boundary")


def test_nonzero_offsets_with_differing_neighbours() raises:
    """Every interesting slot is surrounded by DIFFERING neighbours, so an
    off-by-one on `start` or `end` reads a byte that is provably wrong.
    """
    var vals = List[List[UInt8]]()
    for i in range(12):
        vals.append(_fill(0xAA, 3 + (i % 2)))
        var payload = _fill(0x61, 55)
        payload[54] = UInt8(0x41 + (i % 7))
        vals.append(payload^)
    _assert_matrix(vals, vals, "nonzero-offsets")


def test_long_keys_common_prefix() raises:
    """55-byte keys that all begin `sa_k`: the length and the prefix decide
    nothing."""
    var vals = List[List[UInt8]]()
    for i in range(24):
        var s = String("sa_key_") + String(i) + String("_")
        var v = _bytes(s)
        while len(v) < 55:
            v.append(0x78)  # 'x'
        v[54] = UInt8(0x30 + (i % 10))
        vals.append(v^)
    vals.append(vals[3].copy())
    vals.append(vals[17].copy())
    _assert_matrix(vals, vals, "long common prefix")


def _make_string_col(values: List[String]) raises -> Column[HeapRegion]:
    var sa = StringArray.from_strings(values)
    return Column.from_string(sa^)


def _make_2col_string_string(
    c0_name: String,
    c1_name: String,
    c0_values: List[String],
    c1_values: List[String],
) raises -> RecordBatch:
    var sb = SchemaBuilder()
    sb.add_field(Field(c0_name, ArrowType.STRING, False))
    sb.add_field(Field(c1_name, ArrowType.STRING, False))
    var schema = sb.build()
    var bldr = RecordBatchBuilder()
    bldr.add_column(_make_string_col(c0_values))
    bldr.add_column(_make_string_col(c1_values))
    return bldr.build(schema^)


def _run_inner_join(
    build: RecordBatch,
    probe: RecordBatch,
    keys: List[String],
) raises -> Tuple[List[Int], List[Int]]:
    var bks = extract_join_key_columns_serial(build, keys)
    var pks = extract_join_key_columns_serial(probe, keys)
    var builder = MultiKeyHashJoinBuilder.build(bks^)
    var bm = List[Int]()
    var pm = List[Int]()
    builder.probe_inner_into(pks, bm, pm)
    return (bm^, pm^)


def _brute_force_inner_pairs(
    b_k0: List[String], b_k1: List[String],
    p_k0: List[String], p_k1: List[String],
) -> List[Int]:
    """The expected (build_row, probe_row) pair set, by BRUTE FORCE."""
    var out = List[Int]()
    for b in range(len(b_k0)):
        for p in range(len(p_k0)):
            if b_k0[b] == p_k0[p] and b_k1[b] == p_k1[p]:
                out.append(b * 100000 + p)
    sort(out)
    return out^


def _observed_inner_pairs(
    bm: List[Int], pm: List[Int]
) -> List[Int]:
    var out = List[Int]()
    for i in range(len(bm)):
        out.append(bm[i] * 100000 + pm[i])
    sort(out)
    return out^


def _assert_pairs_equal(
    got: List[Int], want: List[Int], label: String
) raises:
    assert_equal(
        len(got), len(want), label + ": pair COUNT differs from brute force"
    )
    for i in range(len(want)):
        assert_equal(
            got[i],
            want[i],
            label
            + ": pair "
            + String(i)
            + " differs (encoded build*100000+probe) — got "
            + String(got[i])
            + " want "
            + String(want[i]),
        )


def test_end_to_end_inner_join_matches_brute_force() raises:
    """A real 2-key composite join must reproduce the BRUTE-FORCE pair set
    exactly, as a multiset.
    """
    var b_k0 = List[String]()
    var b_k1 = List[String]()
    for i in range(400):
        var kid = i % 50
        var s = String("sa_key_") + String(kid) + String("_")
        while s.byte_length() < 48 + (kid % 17):
            s += String("x")
        b_k0.append(s)
        b_k1.append(String("grp_") + String(i % 7))
    var build = _make_2col_string_string("k0", "k1", b_k0, b_k1)

    var p_k0 = List[String]()
    var p_k1 = List[String]()
    for i in range(300):
        var kid = i % 60
        var s = String("sa_key_") + String(kid) + String("_")
        while s.byte_length() < 48 + (kid % 17):
            s += String("x")
        p_k0.append(s)
        p_k1.append(String("grp_") + String(i % 7))
    var probe = _make_2col_string_string("k0", "k1", p_k0, p_k1)

    var keys = List[String]()
    keys.append("k0")
    keys.append("k1")

    var want = _brute_force_inner_pairs(b_k0, b_k1, p_k0, p_k1)
    assert_true(
        len(want) > 100,
        "fixture produced too few matches to exercise the chain walk: "
        + String(len(want)),
    )

    var got_pm = _run_inner_join(build, probe, keys)
    _assert_pairs_equal(
        _observed_inner_pairs(got_pm[0], got_pm[1]), want, "inner join"
    )


def test_end_to_end_near_miss_keys_produce_no_matches() raises:
    """Build and probe keys that share a 54-byte prefix and differ in the LAST
    byte only. Brute force says ZERO matches; the join must agree.
    """
    var b_k0 = List[String]()
    var b_k1 = List[String]()
    for _ in range(200):
        var s = String("sa_key_common_prefix_")
        while s.byte_length() < 54:
            s += String("x")
        s += String("A")
        b_k0.append(s)
        b_k1.append(String("g"))
    var build = _make_2col_string_string("k0", "k1", b_k0, b_k1)

    var p_k0 = List[String]()
    var p_k1 = List[String]()
    for _ in range(200):
        var s = String("sa_key_common_prefix_")
        while s.byte_length() < 54:
            s += String("x")
        s += String("B")
        p_k0.append(s)
        p_k1.append(String("g"))
    var probe = _make_2col_string_string("k0", "k1", p_k0, p_k1)

    var keys = List[String]()
    keys.append("k0")
    keys.append("k1")

    var want = _brute_force_inner_pairs(b_k0, b_k1, p_k0, p_k1)
    assert_equal(len(want), 0, "brute force disagrees with the fixture premise")

    var got_pm = _run_inner_join(build, probe, keys)
    _assert_pairs_equal(
        _observed_inner_pairs(got_pm[0], got_pm[1]), want, "near-miss join"
    )


def test_every_byte_position_is_compared() raises:
    """For EVERY length 0..80 and EVERY position p in [0, n), a pair differing
    at EXACTLY p must compare UNEQUAL.
    """
    for n in range(0, 81):
        var vals = List[List[UInt8]]()
        vals.append(_fill(0xAA, 1 + (n % 31)))
        vals.append(_fill(0x61, n))
        for p in range(n):
            var m = _fill(0x61, n)
            m[p] = 0x62
            vals.append(m^)
        _assert_matrix(vals, vals, "byte-position-sweep n=" + String(n))


def main() raises:
    var suite = TestSuite()
    suite.test[test_embedded_nul_bytes]()
    suite.test[test_high_bytes_no_sign_confusion]()
    suite.test[test_prefix_of_pairs_and_empty]()
    suite.test[test_word_boundary_lengths]()
    suite.test[test_nonzero_offsets_with_differing_neighbours]()
    suite.test[test_long_keys_common_prefix]()
    suite.test[test_every_byte_position_is_compared]()
    suite.test[test_end_to_end_inner_join_matches_brute_force]()
    suite.test[test_end_to_end_near_miss_keys_produce_no_matches]()
    suite^.run()
