# =============================================================================
# test_join_key_cse_and_chunk_edges -- `join_key_cse_aliases`' proof (every
# decline, counted) and two edges of `join_output_chunk_bounds`
# =============================================================================
#
# Cases
#   A  An eligible INNER equi-join key aliases; `alias_of` is total (an
#      out-of-range column reads -1, not a raise).
#   B  Each decline returns an EMPTY map and bumps `declines` by one: a non-INNER
#      join, no keys, unequal key lists, a missing build key, a missing probe
#      key, a type mismatch, a type outside the allow-list, a bitmap on one
#      side only, a NULL in the probe key, a NULL in the build key. A second, eligible key in the same call
#      still aliases (a decline skips only its own pair).
#   C  `join_output_chunk_bounds` refuses index lists of unequal length.
#   D  A cut row whose index on another priced column is the outer-join `-1`
#      re-prices only the columns it actually gathers from.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.bitmap import Bitmap
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch, RecordBatchBuilder
from komira_arrow.schema import Field, SchemaBuilder
from komira_arrow.string_array import StringArray
from komira_buffer.heap_region import HeapRegion
from komira_join_assembly.join_chunk_plan import join_output_chunk_bounds
from komira_join_assembly.join_key_cse import (
    join_key_cse_aliases,
    join_key_cse_declines,
    reset_join_key_cse_counters,
)
from komira_plan_ir.logical_plan import JOIN_INNER, JOIN_LEFT


comptime _N: Int = 6


def _i64(n: Int) raises -> Column[HeapRegion]:
    var vals = List[Scalar[DType.int64]]()
    for i in range(n):
        vals.append(Scalar[DType.int64](i))
    return Column.from_primitive(PrimitiveArray[DType.int64].from_list(vals))


def _i32(n: Int) raises -> Column[HeapRegion]:
    var vals = List[Scalar[DType.int32]]()
    for i in range(n):
        vals.append(Scalar[DType.int32](i))
    return Column.from_primitive(PrimitiveArray[DType.int32].from_list(vals))


def _f64(n: Int) raises -> Column[HeapRegion]:
    var vals = List[Scalar[DType.float64]]()
    for i in range(n):
        vals.append(Scalar[DType.float64](i))
    return Column.from_primitive(PrimitiveArray[DType.float64].from_list(vals))


def _strs(n: Int) raises -> Column[HeapRegion]:
    var vals = List[String]()
    for i in range(n):
        vals.append(String("s") + String(i))
    return Column.from_string(StringArray.from_strings(vals))


def _with_bitmap(var col: Column[HeapRegion], null_row: Int) raises -> Column[HeapRegion]:
    """Attach a bitmap; `null_row >= 0` clears that row."""
    var bm = Bitmap.create(col._length)
    for i in range(col._length):
        bm.set(i)
    var nulls = 0
    if null_row >= 0:
        bm.clear(null_row)
        nulls = 1
    col._validity = bm^
    col._null_count = nulls
    return col^


def _batch(var cols: List[Column[HeapRegion]], names: List[String]) raises -> RecordBatch:
    var sb = SchemaBuilder()
    var bb = RecordBatchBuilder()
    for c in range(len(names)):
        sb.add_field(Field(names[c], cols[c].arrow_type, cols[c]._validity.__bool__()))
    for c in range(len(names)):
        bb.add_column(cols[c].share())
    return bb.build(sb.build())


def _l(*xs: String) -> List[String]:
    var out = List[String]()
    for x in xs:
        out.append(String(x))
    return out^


def _probe() raises -> RecordBatch:
    """k64, k32, s, f, v (bitmap, no nulls), n (one NULL), m (bitmap, no
    nulls), w (no bitmap)."""
    var cols = List[Column[HeapRegion]]()
    cols.append(_i64(_N))
    cols.append(_i32(_N))
    cols.append(_strs(_N))
    cols.append(_f64(_N))
    cols.append(_with_bitmap(_i64(_N), -1))
    cols.append(_with_bitmap(_i64(_N), 2))
    cols.append(_with_bitmap(_i64(_N), -1))
    cols.append(_i64(_N))
    return _batch(cols^, _l("k64", "k32", "s", "f", "v", "n", "m", "w"))


def _build() raises -> RecordBatch:
    """x (padding), k64, k32 as INT64 (type mismatch), f, v (no bitmap),
    n (bitmap, no nulls), m (one NULL), w (bitmap, no nulls), s LAST (so a
    negative `alias_of` that wrapped to the end would read a real alias)."""
    var cols = List[Column[HeapRegion]]()
    cols.append(_i64(_N))
    cols.append(_i64(_N))
    cols.append(_i64(_N))
    cols.append(_f64(_N))
    cols.append(_i64(_N))
    cols.append(_with_bitmap(_i64(_N), -1))
    cols.append(_with_bitmap(_i64(_N), 4))
    cols.append(_with_bitmap(_i64(_N), -1))
    cols.append(_strs(_N))
    return _batch(cols^, _l("x", "k64", "k32", "f", "v", "n", "m", "w", "s"))


def test_a_eligible_keys_alias() raises:
    var p = _probe()
    var b = _build()
    reset_join_key_cse_counters()
    var m = join_key_cse_aliases(p, b, _l("k64", "s"), _l("k64", "s"), JOIN_INNER)
    assert_equal(len(m), 9, "§A one entry per build column")
    assert_equal(m.alias_of(1), 0, "§A INT64 key aliases")
    assert_equal(m.alias_of(8), 2, "§A STRING key aliases")
    assert_equal(m.alias_of(0), -1, "§A a non-key build column")
    assert_equal(m.alias_of(-1), -1, "§A below range reads -1")
    assert_equal(m.alias_of(9), -1, "§A past the end reads -1")
    assert_equal(join_key_cse_declines(), 0, "§A no decline")


def _declines(
    lk: List[String], rk: List[String], jt: UInt8, want_declines: Int, tag: String
) raises:
    var p = _probe()
    var b = _build()
    reset_join_key_cse_counters()
    var m = join_key_cse_aliases(p, b, lk, rk, jt)
    assert_equal(len(m), 0, tag + ": empty map")
    assert_equal(join_key_cse_declines(), want_declines, tag + ": declines")


def test_b_each_decline_is_counted() raises:
    _declines(_l("k64"), _l("k64"), JOIN_LEFT, 1, "§B non-inner")
    _declines(List[String](), List[String](), JOIN_INNER, 1, "§B no keys")
    _declines(_l("k64"), _l("k64", "s"), JOIN_INNER, 1, "§B unequal key lists")
    _declines(_l("k64"), _l("nope"), JOIN_INNER, 1, "§B missing build key")
    _declines(_l("nope"), _l("k64"), JOIN_INNER, 1, "§B missing probe key")
    _declines(_l("k32"), _l("k32"), JOIN_INNER, 1, "§B type mismatch")
    _declines(_l("f"), _l("f"), JOIN_INNER, 1, "§B FLOAT64 not admitted")
    _declines(_l("v"), _l("v"), JOIN_INNER, 1, "§B bitmap on the probe only")
    _declines(_l("w"), _l("w"), JOIN_INNER, 1, "§B bitmap on the build only")
    _declines(_l("n"), _l("n"), JOIN_INNER, 1, "§B NULL in the probe key")
    _declines(_l("m"), _l("m"), JOIN_INNER, 1, "§B NULL in the build key")

    # A decline skips only its own pair.
    var p = _probe()
    var b = _build()
    reset_join_key_cse_counters()
    var m = join_key_cse_aliases(p, b, _l("f", "k64"), _l("f", "k64"), JOIN_INNER)
    assert_equal(len(m), 9, "§B mixed: map built")
    assert_equal(m.alias_of(1), 0, "§B mixed: eligible pair aliases")
    assert_equal(m.alias_of(3), -1, "§B mixed: declined pair does not")
    assert_equal(join_key_cse_declines(), 1, "§B mixed: one decline")


# =============================================================================
# join_output_chunk_bounds
# =============================================================================


def _str_batch(values: List[String]) raises -> RecordBatch:
    var sb = SchemaBuilder()
    sb.add_field(Field(String("s"), ArrowType.STRING, False))
    var bb = RecordBatchBuilder()
    bb.add_column(Column.from_string(StringArray.from_strings(values)))
    return bb.build(sb.build())


def test_c_unequal_index_lists_are_refused() raises:
    var left = _str_batch(_l("aa", "bb"))
    var right = _str_batch(_l("cc"))
    var li = List[Int]()
    li.append(0)
    li.append(1)
    var ri = List[Int]()
    ri.append(0)
    var raised = False
    try:
        _ = join_output_chunk_bounds(left, right, li, ri, 8)
    except e:
        raised = True
        assert_true(
            String(e).find("index-list length mismatch left=2 right=1") >= 0,
            "§C message: " + String(e),
        )
    assert_true(raised, "§C unequal lists must raise")


def test_d_cut_row_with_a_null_build_index() raises:
    """Left rows are 4 bytes, right rows 6 bytes, budget 10. Rows 1, 2 and 4
    have a `-1` right index. Per-row ledger (left, right running totals):
      row 0: L4 R6              -> (4, 6)
      row 1: L4 R-1             -> (8, 6)   fits
      row 2: L4 R-1 -> (12, 6)  over: cut at 2; re-price row 2 alone -> (4, 0)
      row 3: L4 R6              -> (8, 6)   fits
      row 4: L4 R-1 -> (12, 6)  over: cut at 4; re-price row 4 alone -> (4, 0)
      row 5: L4 R6              -> (8, 6)   fits
    so the bounds are [0, 2, 4, 6]. A re-price that charged the `-1` right row
    as a real row (6 bytes) would leave (4, 6) after the cut at 2, and row 3
    would push the right total to 12 and cut again at 3."""
    var lv = List[String]()
    var rv = List[String]()
    for _ in range(6):
        lv.append(String("llll"))
        rv.append(String("rrrrrr"))
    var left = _str_batch(lv)
    var right = _str_batch(rv)
    var li = List[Int]()
    var ri = List[Int]()
    for i in range(6):
        li.append(i)
        ri.append(-1 if (i == 1 or i == 2 or i == 4) else i)
    var b = join_output_chunk_bounds(left, right, li, ri, 10)
    var expect = List[Int]()
    expect.append(0)
    expect.append(2)
    expect.append(4)
    expect.append(6)
    assert_equal(len(b), len(expect), "§D bound count")
    for k in range(len(expect)):
        assert_equal(b[k], expect[k], "§D bound " + String(k))


def main() raises:
    var suite = TestSuite()
    suite.test[test_a_eligible_keys_alias]()
    suite.test[test_b_each_decline_is_counted]()
    suite.test[test_c_unequal_index_lists_are_refused]()
    suite.test[test_d_cut_row_with_a_null_build_index]()
    suite^.run()
