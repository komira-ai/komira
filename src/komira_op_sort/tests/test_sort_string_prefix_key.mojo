# =============================================================================
# The prefix-key string sort produces the byte-compare merge sort's permutation
# =============================================================================
#
# The prefix-key path (`_sort_indices_string_prefix_key`, the default of
# `sort_indices_string`) is an accelerator: its permutation must be EXACTLY
# the one the byte-compare merge sort (`sort_indices_string(...,
# prefix_key=False)`, the oracle) produces, including ties (stability),
# nulls, descending, a sliced `_offset`, and BINARY with embedded 0x00 bytes.
#
# Keystone (`test_prefix_key_tiebreak_completeness_shared_prefix`): every row
# shares the first 16 bytes and differs only from byte 17 on. A build that
# skips the tie-break, or misjudges `len > covered`, leaves the rows in the
# radix's stable INPUT order instead of lexicographic order, and the
# comparison with the oracle fails. Planted mutant: `_prefix_key_sort_segment`
# skipping the escalation to the next chunk turns the keystone red.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.string_array import StringArray
from komira_buffer.owned_aligned_buffer import OwnedAlignedBuffer
from komira_arrow.bitmap import Bitmap
from komira_arrow.binary_array import BinaryArray
from komira_op_sort.sort_string import (
    sort_indices_string,
    _sort_indices_string_prefix_key,
)
from komira_buffer.heap_region import HeapRegion


# =============================================================================
# Builders
# =============================================================================


def _str_col(values: List[String]) raises -> Column[HeapRegion]:
    var sa = StringArray.from_strings(values)
    return Column.from_string(sa^)


def _str_col_nullable(
    values: List[String], valid_flags: List[Bool]
) raises -> Column[HeapRegion]:
    """STRING column with an explicit validity bitmap (placeholder rows for
    nulls).
    """
    var n = len(values)
    var int32_size = 4
    var total_bytes = 0
    for i in range(n):
        total_bytes += values[i].byte_length()
    var offsets_buf = OwnedAlignedBuffer((n + 1) * int32_size)
    var off_ptr = offsets_buf.view_typed_mut[DType.int32]()
    (off_ptr + 0).init_pointee_copy(Int32(0))
    var data_buf = OwnedAlignedBuffer(max(total_bytes, 1))
    var data_ptr = data_buf.view_typed_mut[DType.uint8]()
    var offset = 0
    for i in range(n):
        var s = values[i]
        var s_len = s.byte_length()
        if s_len > 0:
            var s_ptr = s.unsafe_ptr().bitcast[UInt8]()
            for k in range(s_len):
                (data_ptr + offset + k).init_pointee_copy((s_ptr + k)[])
        offset += s_len
        (off_ptr + i + 1).init_pointee_copy(Int32(offset))
    offsets_buf.set_length(Int64((n + 1) * int32_size))
    data_buf.set_length(Int64(total_bytes))

    var bm = Bitmap.create(n)
    var null_count = 0
    for i in range(n):
        if valid_flags[i]:
            bm.set(i)
        else:
            null_count += 1

    return Column[HeapRegion](
        arrow_type=ArrowType.STRING,
        data=data_buf^,
        offsets=offsets_buf^,
        validity=bm^,
        length=n,
        null_count=null_count,
        offset=0,
    )


def _assert_perm_equal(
    got: PrimitiveArray[DType.int32],
    oracle: PrimitiveArray[DType.int32],
    label: String,
) raises:
    """Assert the prefix-key permutation is byte-identical to the oracle."""
    assert_equal(got.length, oracle.length)
    for i in range(oracle.length):
        if Int(got.get(i)) != Int(oracle.get(i)):
            raise Error(
                "prefix-key permutation diverged from `_string_lt` oracle at "
                "position " + String(i) + " (" + label + "): got "
                + String(Int(got.get(i))) + ", oracle "
                + String(Int(oracle.get(i)))
            )


def _check_both_dirs(col: Column[HeapRegion], label: String) raises:
    """Drive the prefix path + the oracle (OFF path) for ASC and DESC; assert
    byte-identical."""
    var asc_oracle = sort_indices_string(col, descending=False, prefix_key=False)
    var asc_got = _sort_indices_string_prefix_key(col, False, True)
    _assert_perm_equal(asc_got, asc_oracle, label + " ASC")

    var desc_oracle = sort_indices_string(col, descending=True, prefix_key=False)
    var desc_got = _sort_indices_string_prefix_key(col, True, False)
    _assert_perm_equal(desc_got, desc_oracle, label + " DESC")


# =============================================================================
# Test 1 (KEYSTONE FALSIFIER) — tiebreak completeness: all rows share the
# first 16 bytes, differ only at byte 17+.
# =============================================================================


def test_prefix_key_tiebreak_completeness_shared_prefix() raises:
    """Every row shares the first 16 bytes (== the 2-chunk prefix window) and
    differs only at byte 17+. This forces ONE giant equal-chunk collision group:
    the radix cannot order it, so the WHOLE group MUST fall to `_string_lt`.

    FAILS ON CURRENT CODE (a tiebreak-skipping / mis-flagged-`len>covered`
    build): the rows come out in radix-stable INPUT order, NOT the `_string_lt`
    total order, and the assert against the oracle FAILS. The correct build
    flags every row (`len > 16`) and routes the run to `_string_lt` -> PASS.

    SIZE NOTE: the single collision group MUST exceed `_INSERTION_SORT_THRESHOLD`
    (32) so the segment goes through the prefix-key RADIX + tiebreak path (small
    segments shortcut straight to `_merge_sort_string`, which would mask a
    tiebreak miss). 200 rows guarantees the radix path is exercised.
    """
    # 16-byte shared prefix; ordinal disambiguator buried at byte 17+ in a
    # SHUFFLED (LCG) input order (so radix-stable != lex order).
    var shared = String("sa_key_prefix___")  # exactly 16 bytes
    assert_equal(shared.byte_length(), 16)
    var values = List[String]()
    var state: UInt64 = 0xFEEDFACE12345678
    for _ in range(200):
        state = state * 6364136223846793005 + 1442695040888963407
        # 6-digit zero-padded ordinal so byte-wise lex order == numeric order
        # at a fixed width; total length stays > 16 (forces needs_tiebreak).
        var ord = Int((state >> 20) % 1000000)
        var tail = String(ord)
        var padded = String("")
        for _ in range(6 - tail.byte_length()):
            padded += "0"
        padded += tail
        var v = shared + String("_") + padded + String("_zzzzzzzz")
        values.append(v)
    var col = _str_col(values)

    var oracle = sort_indices_string(col, descending=False, prefix_key=False)
    var got = _sort_indices_string_prefix_key(col, False, True)
    _assert_perm_equal(got, oracle, "shared-16-prefix")

    # Sanity: the oracle is NOT the identity permutation (input was scrambled),
    # so a build that silently returned input order would visibly diverge.
    var is_identity = True
    for i in range(oracle.length):
        if Int(oracle.get(i)) != i:
            is_identity = False
            break
    assert_true(not is_identity)


# =============================================================================
# Test 2 (COMPANION FALSIFIER) — embedded-NUL BINARY: NUL-pad order != true
# order, so the NUL flag MUST force a tiebreak.
# =============================================================================


def test_prefix_key_embedded_nul_binary() raises:
    """BINARY rows with an embedded `0x00` inside the first 16 bytes. NUL-pad
    encoding can alias / misorder these, so `_row_needs_tiebreak`'s NUL flag
    MUST route them to `_string_lt`. Asserts byte-identity vs the oracle for
    both directions.

    FAILS ON CURRENT CODE (a build that does NOT flag embedded NUL): two rows
    that differ only after an embedded `0x00` pack to equal/misordered keys and
    come out in the wrong order.

    SIZE NOTE: built to > 32 rows so the segment goes through the prefix-key
    RADIX + `run_has_nul` branch rather than the small-segment `_merge_sort_string`
    shortcut (which would mask a missed NUL flag).
    """
    # 64 rows, all sharing the first 3 bytes "ab\0" (embedded NUL at index 2),
    # differing at the trailing byte in a SHUFFLED (LCG) order. The embedded NUL
    # means a NUL-pad-based key would treat byte 2 as a terminator and misorder
    # the trailing-byte discriminator; the run_has_nul branch MUST route the
    # whole group to `_string_lt`.
    var values = List[List[UInt8]]()
    var state: UInt64 = 0x1357924680ABCDEF
    for _ in range(64):
        state = state * 6364136223846793005 + 1442695040888963407
        var tail = UInt8(Int((state >> 24) % 200))
        var row: List[UInt8] = [UInt8(0x61), UInt8(0x62), UInt8(0x00), tail]
        values.append(row^)
    # A couple of shorter rows ("ab") to exercise the length tiebreak under NUL.
    values.append([UInt8(0x61), UInt8(0x62)])
    values.append([UInt8(0x61), UInt8(0x62), UInt8(0x00)])
    var ba = BinaryArray.from_bytes_list(values)
    var col = Column.from_binary(ba^)

    var asc_oracle = sort_indices_string(col, descending=False, prefix_key=False)
    var asc_got = _sort_indices_string_prefix_key(col, False, True)
    _assert_perm_equal(asc_got, asc_oracle, "embedded-nul ASC")

    var desc_oracle = sort_indices_string(col, descending=True, prefix_key=False)
    var desc_got = _sort_indices_string_prefix_key(col, True, False)
    _assert_perm_equal(desc_got, desc_oracle, "embedded-nul DESC")


# =============================================================================
# Test 3 — basic ASCII lex (ASC + DESC byte-identity).
# =============================================================================


def test_prefix_key_basic_ascii() raises:
    var values: List[String] = ["banana", "apple", "cherry", "apple", "date"]
    _check_both_dirs(_str_col(values), "basic-ascii")


# =============================================================================
# Test 4 — length tie-break (prefix sorts before longer).
# =============================================================================


def test_prefix_key_length_tiebreak() raises:
    var values: List[String] = ["app", "apple", "ap", "apple", "a", "applepie"]
    _check_both_dirs(_str_col(values), "length-tiebreak")


# =============================================================================
# Test 5 — stability (equal keys preserve original order).
# =============================================================================


def test_prefix_key_stability() raises:
    var values: List[String] = ["B", "A", "B", "A", "C", "B", "A", "C", "B"]
    _check_both_dirs(_str_col(values), "stability")


# =============================================================================
# Test 6 — all-equal column (one giant tiebreak group, must stay stable).
# =============================================================================


def test_prefix_key_all_equal() raises:
    var values = List[String]()
    for _ in range(40):
        values.append(String("the_same_long_value_over_16_bytes_xx"))
    _check_both_dirs(_str_col(values), "all-equal")


# =============================================================================
# Test 7 — all-distinct, short keys (radix resolves everything, tiebreak empty).
# =============================================================================


def test_prefix_key_all_distinct_short() raises:
    var values = List[String]()
    # 200 distinct 5-7 byte values in scrambled order.
    var state: UInt64 = 0xABCDEF0123456789
    for _ in range(200):
        state = state * 6364136223846793005 + 1442695040888963407
        var a = Int((state >> 17) % 26)
        var b = Int((state >> 23) % 26)
        var c = Int((state >> 29) % 26)
        var d = Int((state >> 35) % 26)
        var s = String("k_")
        s += chr(97 + a)
        s += chr(97 + b)
        s += chr(97 + c)
        s += chr(97 + d)
        values.append(s)
    _check_both_dirs(_str_col(values), "all-distinct-short")


# =============================================================================
# Test 8 — nulls (NULLS FIRST asc / NULLS LAST desc, stable).
# =============================================================================


def test_prefix_key_nulls() raises:
    var values: List[String] = [
        "banana_over_sixteen_bytes_aaa",
        "",
        "apple_over_sixteen_bytes_bbb",
        "",
        "cherry_over_sixteen_bytes_ccc",
        "apple_over_sixteen_bytes_bbb",
        "",
    ]
    var valid: List[Bool] = [True, False, True, False, True, True, False]
    var col = _str_col_nullable(values, valid)
    _check_both_dirs(col, "nulls")


# =============================================================================
# Test 9 — wide shared-prefix keys: "sa_key_" + ordinal, 48-64B, low cardinality
# over many rows (the two-chunk escalation exercise).
# =============================================================================


def _make_wide_value(i: Int) -> String:
    """Mirror bench/engine/sa_string_movement.mojo::_make_wide_value."""
    var KEY_BYTES_MIN = 48
    var KEY_BYTES_MAX = 64
    var target = KEY_BYTES_MIN + (i % (KEY_BYTES_MAX - KEY_BYTES_MIN + 1))
    var head = String("sa_key_") + String(i) + String("_")
    var out = head
    var pad = target - out.byte_length()
    if pad < 0:
        pad = 0
    for _ in range(pad):
        out += "x"
    return out^


def test_prefix_key_wide_shared_prefix() raises:
    """Wide shared-prefix fixture: ~300 distinct wide values, 4000 rows drawn LCG
    over them. Shared `"sa_key_"` prefix forces chunk-0 collisions; the 2-chunk
    escalation must resolve the ordinal. Byte-identity vs the oracle for both
    directions."""
    var n_distinct = 300
    var distinct = List[String]()
    for i in range(n_distinct):
        distinct.append(_make_wide_value(i))
    var row_values = List[String]()
    var state: UInt64 = 0x0BADF00DD15EA5E5
    for _ in range(4000):
        state = state * 6364136223846793005 + 1442695040888963407
        var code = Int((state >> 19) % UInt64(n_distinct))
        row_values.append(distinct[code])
    _check_both_dirs(_str_col(row_values), "sa-sort-shape")


# =============================================================================
# Test 10 — empty / single-row edge cases.
# =============================================================================


def test_prefix_key_edge_cases() raises:
    var empty = List[String]()
    var ec = _str_col(empty)
    var ei = _sort_indices_string_prefix_key(ec, False, True)
    assert_equal(ei.length, 0)

    var one: List[String] = ["solo"]
    var oc = _str_col(one)
    var oi = _sort_indices_string_prefix_key(oc, False, True)
    assert_equal(oi.length, 1)
    assert_equal(Int(oi.get(0)), 0)


# =============================================================================
# Test 11 — sliced batch: _offset propagation (obligation §4.5).
# =============================================================================


def test_prefix_key_slice_offset() raises:
    """The prefix path must read offsets[col_offset + r], honoring Column._offset
    for sliced batches. Builds a 6-row buffer viewed as rows 2..6 and asserts the
    prefix permutation == the oracle over the sliced view (both directions)."""
    var all_values: List[String] = [
        "zz_skip0_over_sixteen_bytes",
        "zz_skip1_over_sixteen_bytes",
        "delta_over_sixteen_bytes_dd",
        "alpha_over_sixteen_bytes_aa",
        "charlie_over_sixteen_byte_c",
        "bravo_over_sixteen_bytes_bb",
    ]
    var n_total = len(all_values)
    var int32_size = 4
    var total_bytes = 0
    for i in range(n_total):
        total_bytes += all_values[i].byte_length()
    var offsets_buf = OwnedAlignedBuffer((n_total + 1) * int32_size)
    var off_ptr = offsets_buf.view_typed_mut[DType.int32]()
    (off_ptr + 0).init_pointee_copy(Int32(0))
    var data_buf = OwnedAlignedBuffer(max(total_bytes, 1))
    var data_ptr = data_buf.view_typed_mut[DType.uint8]()
    var offset = 0
    for i in range(n_total):
        var s = all_values[i]
        var s_len = s.byte_length()
        if s_len > 0:
            var s_ptr = s.unsafe_ptr().bitcast[UInt8]()
            for k in range(s_len):
                (data_ptr + offset + k).init_pointee_copy((s_ptr + k)[])
        offset += s_len
        (off_ptr + i + 1).init_pointee_copy(Int32(offset))
    offsets_buf.set_length(Int64((n_total + 1) * int32_size))
    data_buf.set_length(Int64(total_bytes))

    var sliced_col = Column[HeapRegion](
        arrow_type=ArrowType.STRING,
        data=data_buf^,
        offsets=offsets_buf^,
        validity=Optional[Bitmap[HeapRegion]](None),
        length=4,
        null_count=0,
        offset=2,
    )
    _check_both_dirs(sliced_col, "slice-offset")


# =============================================================================
# Suite registration
# =============================================================================


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
