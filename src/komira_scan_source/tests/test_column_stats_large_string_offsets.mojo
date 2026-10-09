# =============================================================================
# LARGE_STRING offsets must not be read at Int32 width in column stats
# =============================================================================
#
# THE HAZARD. If `_ColAccum.__init__` (column_stats_accum.mojo) tags BOTH
# `ArrowType.STRING` and `ArrowType.LARGE_STRING` as `_ACC_KIND_STRING`, and
# `_scan_string_column` then reads that column's offsets with
# `get_typed[Int32]` unconditionally: `get_typed` is ELEMENT-indexed
# (`(ptr + index * size_of[T]())` in owned_aligned_buffer.mojo), so on
# an Int64 offsets buffer index k returns low32(O[k/2]) for even k and
# high32(O[k/2]) for odd k.
#
# WORKED EXAMPLE, which is what the assertions below encode. For
# ["alpha", "bb"] the true Int64 offsets are [0, 5, 7]. The Int32 reads are
#   k=0 -> low32(O[0])  = 0
#   k=1 -> high32(O[0]) = 0
#   k=2 -> low32(O[1])  = 5
# so row 0 decodes as span (0,0) = "" and row 1 as span (0,5) = "alpha".
#   avg_size_bytes: (0 + 5) / 2 = 2.5   TRUTH: (5 + 2) / 2 = 3.5
#   min:            ""                  TRUTH: "alpha"
#   max:            "alpha"             TRUTH: "bb"
# The wrong stats feed the optimizer's cardinality and selectivity estimates.
#
# WHY EXACTLY 2 ROWS. At row index 2 the read gives start=low32(O[1]) and
# end=high32(O[1])=0, so `nbytes = end - start` is -(length of the first
# string) and reaches the `List[UInt8](capacity=nbytes + 1)` allocation. That is an
# allocator abort, not an assertable value. 2 rows keeps every read in bounds
# (max index 2 -> 12 bytes of a 24-byte buffer, so the debug_assert in
# get_typed does not fire either) and is sufficient to falsify the site.
#
# A byte-identical STRING control passes either way.
# =============================================================================

from std.testing import (
    TestSuite, assert_almost_equal, assert_equal, assert_false, assert_true
)

from komira_arrow.arrow_types import ArrowType
from komira_arrow.schema import RecordBatch
from komira_arrow.column import Column
from komira_arrow.dictionary_array import StringDictionaryArray
from komira_arrow.large_string_array import LargeStringArray
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.schema import Field, RecordBatchBuilder, SchemaBuilder
from komira_arrow.string_array import StringArray
from komira_collections.slab import Slab
from komira_buffer.heap_region import HeapRegion
from komira_scan_source.column_stats import compute_column_stats


def _two_values() -> List[String]:
    var vals = List[String]()
    vals.append(String("alpha"))  # 5 bytes
    vals.append(String("bb"))  # 2 bytes  => true offsets [0, 5, 7]
    return vals^


def _assert_stats_match_the_true_strings(at: ArrowType) raises:
    """Compute stats over the 2-row fixture and assert the TRUE values.

    The expected values are identical for STRING and LARGE_STRING by
    construction — the two columns hold byte-identical strings and differ
    only in offsets width — so one assertion body serves both the falsifier
    and its control.
    """
    var sb = SchemaBuilder()
    sb.add_field(Field("v", at, nullable=False))
    var schema = sb.build()

    var vals = _two_values()
    var column = (
        Column.from_large_string(LargeStringArray.from_strings(vals))
        if at == ArrowType.LARGE_STRING
        else Column.from_string(StringArray.from_strings(vals))
    )

    var b = RecordBatchBuilder()
    b.add_column(column^)
    var sl = Slab[RecordBatch].create(1)
    sl.append(b.build(schema.copy())^)

    var stats = compute_column_stats(sl, schema)
    ref s = stats[0]
    assert_equal(s.null_count, 0, "no nulls in the fixture")
    assert_almost_equal(
        s.avg_size_bytes,
        3.5,
        msg="avg_size_bytes over 5- and 2-byte strings is (5+2)/2 = 3.5",
    )
    assert_equal(
        s.min.value.value().string_val, String("alpha"), "lexicographic MIN"
    )
    assert_equal(
        s.max.value.value().string_val, String("bb"), "lexicographic MAX"
    )


def test_large_string_column_stats_read_int64_offsets() raises:
    """Stats over a LARGE_STRING column must match the true string values.

    An Int32-strided read yields avg 2.5 / min "" / max "alpha" — the
    decode of ["alpha", "bb"] as ["", "alpha"].
    """
    _assert_stats_match_the_true_strings(ArrowType.LARGE_STRING)


def test_string_column_stats_control() raises:
    """CONTROL: byte-identical STRING input. Passes either way."""
    _assert_stats_match_the_true_strings(ArrowType.STRING)


# =============================================================================
# THE SCHEMA/COLUMN DISAGREEMENT — stats must DEGRADE, never RAISE.
# =============================================================================
#
# `compute_column_stats` picks the scanner from `schema.field_arrow_type(c)`
# but the width must come from `col.arrow_type` — only the column knows how
# wide the buffer it is about to stride actually is. Those two can disagree,
# and the disagreement lands squarely in `_scan_string_column`: a DICTIONARY
# column under a declared STRING / LARGE_STRING field has a NON-NULL
# `_offsets` (its dict-VALUE offsets), and `carries_offsets(DICTIONARY)` is
# False.
#
# Routing that through `offset_width_bytes_or_raise` would RAISE — inside
# `InMemorySource.get_column_stats`, i.e. during OPTIMIZATION, i.e. it fails
# the query. An Int32-strided read of this shape returns WRONG stats; turning
# wrong stats into a failed query would be a REGRESSION, not a fix, so the shape
# takes a counting arm instead: exact null count, no min/max, NDV Absent —
# which is the stats this same column gets when its schema field honestly
# says DICTIONARY.
# =============================================================================


def test_dict_column_under_string_field_degrades_and_does_not_raise() raises:
    """A DICTIONARY column beneath a declared STRING field must not raise."""
    var sb = SchemaBuilder()
    # The field LIES about the column — deliberately. That is the shape.
    sb.add_field(Field("v", ArrowType.STRING, nullable=False))
    var schema = sb.build()

    var dict_values = List[String]()
    dict_values.append(String("alpha"))
    dict_values.append(String("bb"))
    var indices = List[Int32]()
    indices.append(Int32(0))
    indices.append(Int32(1))
    indices.append(Int32(0))
    var dict_col = Column.from_dictionary(
        StringDictionaryArray.from_parts(
            PrimitiveArray[DType.int32].from_list(indices.copy()),
            StringArray.from_strings(dict_values.copy()),
        )
    )

    var b = RecordBatchBuilder()
    b.add_column(dict_col^)
    var sl = Slab[RecordBatch].create(1)
    sl.append(b.build(schema.copy())^)

    # THE ASSERTION IS THAT THIS RETURNS. A raise here fails the query.
    var stats = compute_column_stats(sl, schema)
    ref s = stats[0]
    assert_equal(s.null_count, 0, "exact null count survives the degraded arm")
    assert_false(
        Bool(s.min.value), "no MIN is claimed for a column we did not scan"
    )
    assert_false(
        Bool(s.max.value), "no MAX is claimed for a column we did not scan"
    )
    assert_true(
        s.distinct_count.is_absent(),
        "no NDV (not Exact 0) is claimed for a column we did not scan",
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
