# =============================================================================
# `union_compute._bytes_for` must NOT answer **1** FOR BOOL: the answer would be
# WRONG RATHER THAN MISSING. NO RAISE. WRONG ROWS.
# =============================================================================
#
# This is the OVER-READ regime of the BOOL byte-width class — the one that
# returns wrong data instead of an error.
#
#     def _bytes_for(arrow_type: ArrowType) -> Int:
#         if arrow_type == ArrowType.INT8 or ... or arrow_type == ArrowType.BOOL:
#             return 1
#
# ⚠ IT NAMES BOOL. That is exactly what makes it worse than a missing arm, and
# it is why a "does this def mention ArrowType.BOOL" heuristic scores it SAFE.
# Naming the type and then handing it a per-element BYTE width is not a
# bit-packed arm; it is the wrong answer stated confidently.
#
# WHAT IT WOULD DO. `_take_column_dispatch` has arms for STRING/BINARY, LARGE_*,
# LIST/MAP, STRUCT, UNION_*, and then `elif _bytes_for(at) > 0:` — so BOOL,
# scoring 1, lands in `_take_fixed_width`, which does
#
#     var src_off = (src._offset + i) * elem        # elem == 1
#     data_buf.view_range_mut(r * elem, elem).copy_from_view_at(...)
#
# i.e. it copies BYTE i of a bit-packed buffer and calls it ROW i, into an
# output buffer of `n` bytes that the consumer then reads as `n` BITS. Eight
# rows collapse into one byte's worth of source and the other seven bytes are
# read past the bitmap. `_eq_at` has the identical `(offset + i) * w + k`
# byte-compare.
#
# ★ REACHABLE, NOT LATENT, AND NOT ONLY THROUGH UNIONS despite the module name:
#   * `agg_struct._build_struct_key_agg_output` calls `_take_column_dispatch`
#     on a STRUCT key column, which recurses per child — so `GROUP BY <struct
#     with a bool field>` materialises wrong bools.
#   * `compiler_helpers.gather_batch_dispatch` routes LIST / STRUCT / MAP /
#     UNION_* columns here, so any SORT or JOIN gather over a nested column
#     with a bool leaf does too.
#
# THE FIX IS NOT "make it raise". `_bytes_for` returns 0 for the layouts that
# have no fixed width and every caller treats 0 as "route elsewhere", so BOOL
# joins that set and gets a real bit-packed arm on the shared
# `bitmap.gather_bits_aligned_buffer` — the same primitive as every other
# indexed member of this class.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.boolean_array import BooleanArray
from komira_arrow.column import Column
from komira_buffer.heap_region import HeapRegion
from komira_column_kernels.union_compute import _bytes_for, _take_column_dispatch


def _expected_flag(i: Int) -> Bool:
    """Period 3 — the bit pattern differs in every byte, so a copy that reads
    byte `i` instead of bit `i` cannot coincidentally agree."""
    return i % 3 == 0


def _bool_column(n: Int) raises -> Column[HeapRegion]:
    var flags = BooleanArray.allocate(n)
    for i in range(n):
        flags.set(i, _expected_flag(i))
    return Column.from_boolean(flags)


def test_bytes_for_does_not_claim_bool_has_a_byte_width() raises:
    """The width table itself.

    Zero is this table's "no fixed per-element width" answer — it is what it
    returns for STRING, LIST and STRUCT, and every caller routes on `> 0`. BOOL
    belongs in that set: its buffer is `(n + 7) >> 3` bytes. Answering 1 is not
    a conservative estimate, it is a claim that indexing at `row * 1` addresses
    a row, which it does not.
    """
    assert_equal(
        _bytes_for(ArrowType.BOOL),
        0,
        "_bytes_for(BOOL) must be 0 (no fixed per-element byte width), not a"
        " byte count — a nonzero answer routes BOOL into the fixed-width take",
    )
    # The negation: the table must still answer for the types that DO have a
    # width, or this "fix" has disabled the fixed-width take for everything.
    assert_equal(_bytes_for(ArrowType.INT8), 1)
    assert_equal(_bytes_for(ArrowType.INT16), 2)
    assert_equal(_bytes_for(ArrowType.INT32), 4)
    assert_equal(_bytes_for(ArrowType.INT64), 8)
    assert_equal(_bytes_for(ArrowType.FLOAT64), 8)


def test_take_column_dispatch_carries_a_bool_column() raises:
    """31 rows, gathered in a non-monotone order that crosses every byte."""
    comptime N = 31
    var col = _bool_column(N)

    var indices = List[Int]()
    for k in range(N):
        indices.append((k * 7) % N)

    var out = _take_column_dispatch(col, indices)
    assert_equal(out.arrow_type, ArrowType.BOOL)
    assert_equal(out._length, N)

    var got = out.as_boolean()
    for r in range(N):
        var src = (r * 7) % N
        assert_equal(
            got.get(r),
            _expected_flag(src),
            "_take_column_dispatch read BYTE "
            + String(src)
            + " where row "
            + String(src)
            + " is a BIT (out row "
            + String(r)
            + ")",
        )


def test_take_column_dispatch_over_an_already_offset_bool_column() raises:
    """`src._offset + indices[r]` are BOTH bit indices for BOOL.

    A fix that treats the index as a bit position but `_offset` as a byte
    address passes the test above (whose `_offset` is 0) and fails here. The
    same composition pin every other site in this class carries.
    """
    comptime N = 40
    var base = _bool_column(N)
    var win = base.share()
    win._offset = 5
    win._length = N - 5

    var indices = List[Int]()
    for r in range(N - 5):
        if r % 4 != 1:
            indices.append(r)

    var out = _take_column_dispatch(win, indices)
    assert_equal(out._length, len(indices))
    var got = out.as_boolean()
    for r in range(len(indices)):
        var src = indices[r] + 5
        assert_equal(
            got.get(r),
            _expected_flag(src),
            "windowed bool lost at out row " + String(r),
        )


def test_take_column_dispatch_bool_with_no_indices() raises:
    """Empty take: `(0 + 7) >> 3` is 0 bytes, and the column must still build."""
    var col = _bool_column(16)
    var indices = List[Int]()
    var out = _take_column_dispatch(col, indices)
    assert_equal(out.arrow_type, ArrowType.BOOL)
    assert_equal(out._length, 0)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
