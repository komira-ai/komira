# =============================================================================
# Tests for `copy_table` / `share_table` -- the CHUNK-SEQUENCE duals of
# `copy_batch` / `share_batch`
# =============================================================================
#
# ⭐ WHY THE PAIR IS TESTED IN ONE FILE WHERE `into_single_batch` /
# `to_record_batch` ARE DELIBERATELY KEPT APART. Those two have OPPOSITE
# contracts over the same input and the cheapest way to destroy that design is
# to unify them, so their tests are textually separated
# (`test_table_to_record_batch.mojo`'s header says so). These two are the
# opposite case: they are the SAME contract over the same input, differing in
# exactly ONE observable -- whether the result ALIASES the source's buffers --
# and each is the other's mutant. Asserting them side by side is what makes
# that one difference the subject rather than an incidental detail:
#
#   `copy_table(t)`   buffer addresses DIFFER  -> independent ownership
#   `share_table(t)`  buffer addresses EQUAL   -> aliasing, refcounted
#
# ⛔ A `copy_table` silently implemented as a share passes EVERY value
# assertion in this file. The address assertions are the only thing that can
# fail, and they are the reason `_data_ptr_addr` is here.
#
# WHAT IS PINNED
#   1. CHUNKING SURVIVES. `num_chunks()`, the per-chunk row counts, the chunk
#      ORDER and `num_rows()` are preserved by both. A copy that CONCATENATED
#      would read back every value correctly and still be wrong: the whole
#      point of the `Table` type is that a result can be handed on WITHOUT a
#      stitch.
#   2. ZERO CHUNKS KEEPS THE SCHEMA. `Table` stores its schema independently of
#      its chunks, so an empty result is representable as itself. Both
#      primitives must carry the schema across -- `num_columns()` reads it,
#      and a schema-less empty result breaks a downstream Project.
#   3. VAR-LEN COLUMNS, ON THE OFFSETS. A string column has TWO buffers and a
#      value differential is structurally blind to an offsets defect (rebasing
#      wrongly and reading back with the same wrong rebase reproduces the input
#      exactly -- `test_table_to_record_batch.mojo` item 4 makes the same point).
#      The offsets are asserted as NUMBERS.
#   4. LIFETIME. A `copy_table` outlives its source because it owns fresh
#      buffers; a `share_table` outlives its source because the Arc keeps the
#      regions alive. Both are asserted by building in a helper whose source
#      DROPS on return -- a missed refcount reads freed/reused bytes.
# =============================================================================

from std.testing import assert_equal, assert_not_equal, assert_true

from komira_core.arrow.arrow_types import ArrowType
from komira_core.arrow.column import Column
from komira_core.arrow.primitive_array import PrimitiveArray
from komira_core.arrow.record_batch import RecordBatch, RecordBatchBuilder
from komira_core.arrow.schema import Field, Schema, SchemaBuilder
from komira_core.arrow.string_array import StringArray
from komira_core.arrow.table import Table
from komira_core.helpers.compiler_helpers import copy_table, share_table
from komira_core.io.heap_region import HeapRegion


# =============================================================================
# Fixtures
# =============================================================================


def _i64_schema() raises -> Schema:
    return Schema.from_fields_1(Field("v", ArrowType.INT64, False))


def _i64_batch(vals: List[Int]) raises -> RecordBatch:
    var arr = PrimitiveArray[DType.int64].allocate(len(vals))
    for i in range(len(vals)):
        arr.set(i, Int64(vals[i]))
    var b = RecordBatchBuilder.with_capacity(1)
    b.add_column(Column.from_primitive[DType.int64](arr^))
    var sch = _i64_schema()
    return b.build(sch^)


def _str_schema() raises -> Schema:
    return Schema.from_fields_1(Field("s", ArrowType.STRING, False))


def _str_batch(vals: List[String]) raises -> RecordBatch:
    var sa = StringArray.from_strings(vals)
    var b = RecordBatchBuilder.with_capacity(1)
    b.add_column(Column.from_string(sa^))
    var sch = _str_schema()
    return b.build(sch^)


def _three_chunk_i64() raises -> Table:
    """3 chunks of DIFFERENT lengths -- so a boundary change is visible in the
    per-chunk row counts and not merely in the total."""
    var chunks = List[RecordBatch]()
    chunks.append(_i64_batch([10, 11]))
    chunks.append(_i64_batch([20, 21, 22]))
    chunks.append(_i64_batch([30]))
    return Table.from_chunks(chunks^, _i64_schema())


def _two_chunk_str() raises -> Table:
    var chunks = List[RecordBatch]()
    chunks.append(_str_batch([String("alpha"), String("b")]))
    chunks.append(_str_batch([String(""), String("gamma-long-value")]))
    return Table.from_chunks(chunks^, _str_schema())


def _zero_chunk_i64() raises -> Table:
    """An EMPTY result that still has a schema -- 0 chunks, 2 declared columns.

    Two columns on purpose: a primitive that carried the schema by accident
    (e.g. by rebuilding it from chunk 0) cannot fake this at all, because there
    is no chunk 0."""
    var sb = SchemaBuilder()
    sb.add_field(Field("a", ArrowType.INT64, False))
    sb.add_field(Field("b", ArrowType.STRING, True))
    var chunks = List[RecordBatch]()
    return Table.from_chunks(chunks^, sb.build())


# ---- readers ----------------------------------------------------------------


def _data_ptr_addr(ref batch: RecordBatch) -> Int:
    """Address of column 0's values buffer -- the identity of the allocation.

    THE discriminator between the two primitives. Same technique (and same
    rationale) as `test_table_to_record_batch.mojo:_data_ptr_addr`."""
    return Int(batch.column_at(0)._data.view_typed_ro[DType.uint8]())


def _i64_values(ref col: Column[HeapRegion]) -> List[Int]:
    var out = List[Int](capacity=col._length)
    for i in range(col._length):
        out.append(Int(col._data.get_typed[Int64](i)))
    return out^


def _i32_offsets(ref col: Column[HeapRegion]) raises -> List[Int]:
    """The Int32 offsets buffer, all `length + 1` entries."""
    var out = List[Int](capacity=col._length + 1)
    for i in range(col._length + 1):
        out.append(Int(col._offsets.value().get_typed[Int32](i)))
    return out^


def _str_values(ref col: Column[HeapRegion]) raises -> List[String]:
    var offs = _i32_offsets(col)
    var out = List[String](capacity=col._length)
    for i in range(col._length):
        var s = String("")
        for b in range(offs[i], offs[i + 1]):
            s += chr(Int(col._data.get_typed[UInt8](b)))
        out.append(s^)
    return out^


def _assert_int_list(got: List[Int], want: List[Int], label: String) raises:
    assert_equal(len(got), len(want), label + ": length")
    for i in range(len(want)):
        assert_equal(got[i], want[i], label + ": element " + String(i))


def _assert_three_chunk_shape_and_values(
    ref t: Table, label: String
) raises:
    """The FULL contract of `_three_chunk_i64()`: chunking, order, values."""
    assert_equal(t.num_chunks(), 3, label + ": chunk count -- NOT concatenated")
    assert_equal(t.num_rows(), 6, label + ": total rows")
    assert_equal(t.num_columns(), 1, label + ": columns")
    assert_equal(t.schema().field_name(0), String("v"), label + ": field name")
    assert_true(
        t.schema().field_arrow_type(0) == ArrowType.INT64,
        label + ": field type",
    )
    assert_equal(t.chunks()[0].num_rows(), 2, label + ": chunk 0 rows")
    assert_equal(t.chunks()[1].num_rows(), 3, label + ": chunk 1 rows")
    assert_equal(t.chunks()[2].num_rows(), 1, label + ": chunk 2 rows")
    _assert_int_list(
        _i64_values(t.chunks()[0].column_at(0)), [10, 11], label + ": chunk 0"
    )
    _assert_int_list(
        _i64_values(t.chunks()[1].column_at(0)),
        [20, 21, 22],
        label + ": chunk 1",
    )
    _assert_int_list(
        _i64_values(t.chunks()[2].column_at(0)), [30], label + ": chunk 2"
    )


# =============================================================================
# copy_table
# =============================================================================


def test_copy_table_preserves_chunking_order_values_and_schema() raises:
    print("test_copy_table_preserves_chunking_order_values_and_schema")
    var src = _three_chunk_i64()
    var dup = copy_table(src)
    _assert_three_chunk_shape_and_values(dup, "copy")
    # The SOURCE is borrowed, not consumed: it still reads correctly after.
    _assert_three_chunk_shape_and_values(src, "source-after-copy")
    print("  ok")


def test_copy_table_buffers_are_independent_of_the_source() raises:
    """⭐ THE DISCRIMINATOR. Every chunk's values buffer is a DIFFERENT
    allocation. A `copy_table` implemented as `share_table` passes every value
    assertion in this file and fails exactly here."""
    print("test_copy_table_buffers_are_independent_of_the_source")
    var src = _three_chunk_i64()
    var dup = copy_table(src)
    assert_equal(dup.num_chunks(), src.num_chunks(), "chunk counts agree")
    for i in range(src.num_chunks()):
        assert_not_equal(
            _data_ptr_addr(dup.chunks()[i]),
            _data_ptr_addr(src.chunks()[i]),
            "chunk " + String(i) + ": copy must NOT alias the source buffer",
        )
    print("  ok")


def _copy_then_drop_source() raises -> Table:
    """Build a table as a LOCAL, copy it, return ONLY the copy. The source
    drops on return -- a copy that aliased it would read freed bytes."""
    var src = _three_chunk_i64()
    var dup = copy_table(src)
    return dup^


def test_copy_table_survives_source_destruction() raises:
    print("test_copy_table_survives_source_destruction")
    var dup = _copy_then_drop_source()
    _assert_three_chunk_shape_and_values(dup, "copy-after-source-drop")
    print("  ok")


def test_copy_table_zero_chunks_keeps_the_schema() raises:
    """An EMPTY result is copied as an empty result -- 0 chunks, schema intact.

    ⛔ NOT as a 1-chunk table carrying a 0-row batch: that is a legitimate way
    to SPELL an empty relation elsewhere (`InMemorySource.from_record_batches`
    requires it) but it is NOT what this table was, and a duplication primitive
    that changes the chunk count has changed the result's physical shape."""
    print("test_copy_table_zero_chunks_keeps_the_schema")
    var src = _zero_chunk_i64()
    var dup = copy_table(src)
    assert_equal(dup.num_chunks(), 0, "zero chunks stay zero")
    assert_equal(dup.num_rows(), 0, "zero rows")
    assert_equal(dup.num_columns(), 2, "the SCHEMA's column count survives")
    assert_equal(dup.schema().field_name(0), String("a"), "field 0 name")
    assert_equal(dup.schema().field_name(1), String("b"), "field 1 name")
    assert_true(
        dup.schema().field_arrow_type(1) == ArrowType.STRING,
        "field 1 type",
    )
    print("  ok")


def test_copy_table_one_chunk_is_still_a_copy() raises:
    """The 1-chunk table is the shape every unchunked driver produces. It is
    NOT move-taken and NOT shared -- `copy_table` borrows its argument."""
    print("test_copy_table_one_chunk_is_still_a_copy")
    var chunks = List[RecordBatch]()
    chunks.append(_i64_batch([7, 8, 9]))
    var src = Table.from_chunks(chunks^, _i64_schema())
    var dup = copy_table(src)
    assert_equal(dup.num_chunks(), 1, "one chunk")
    assert_equal(src.num_chunks(), 1, "source keeps its chunk")
    assert_not_equal(
        _data_ptr_addr(dup.chunks()[0]),
        _data_ptr_addr(src.chunks()[0]),
        "one-chunk copy must not alias",
    )
    _assert_int_list(
        _i64_values(dup.chunks()[0].column_at(0)), [7, 8, 9], "one-chunk values"
    )
    print("  ok")


# =============================================================================
# share_table
# =============================================================================


def test_share_table_aliases_the_source_buffers() raises:
    """⭐ THE OTHER HALF OF THE DISCRIMINATOR. Every chunk's values buffer is
    the SAME allocation. A `share_table` implemented as `copy_table` fails
    exactly here and nowhere else."""
    print("test_share_table_aliases_the_source_buffers")
    var src = _three_chunk_i64()
    var sh = share_table(src)
    assert_equal(sh.num_chunks(), src.num_chunks(), "chunk counts agree")
    for i in range(src.num_chunks()):
        assert_equal(
            _data_ptr_addr(sh.chunks()[i]),
            _data_ptr_addr(src.chunks()[i]),
            "chunk " + String(i) + ": share MUST alias the source buffer",
        )
    print("  ok")


def test_share_table_reads_identically_to_copy_table() raises:
    """The byte-equivalence oracle: the two primitives differ ONLY in aliasing.
    Asserted on chunking, schema and values -- and, below, on offsets."""
    print("test_share_table_reads_identically_to_copy_table")
    var src = _three_chunk_i64()
    var sh = share_table(src)
    _assert_three_chunk_shape_and_values(sh, "share")
    var dup = copy_table(src)
    assert_equal(sh.num_chunks(), dup.num_chunks(), "share vs copy: chunks")
    assert_equal(sh.num_rows(), dup.num_rows(), "share vs copy: rows")
    for i in range(sh.num_chunks()):
        _assert_int_list(
            _i64_values(sh.chunks()[i].column_at(0)),
            _i64_values(dup.chunks()[i].column_at(0)),
            "share vs copy: chunk " + String(i),
        )
    print("  ok")


def test_both_primitives_preserve_string_offsets_per_chunk() raises:
    """VAR-LEN: a string column has an offsets buffer AND a data buffer, and a
    value read is blind to an offsets defect that the read itself undoes. The
    offsets are asserted as NUMBERS, per chunk, for BOTH primitives."""
    print("test_both_primitives_preserve_string_offsets_per_chunk")
    var src = _two_chunk_str()
    var dup = copy_table(src)
    var sh = share_table(src)
    assert_equal(dup.num_chunks(), 2, "copy: chunk count")
    assert_equal(sh.num_chunks(), 2, "share: chunk count")
    # chunk 0: "alpha" (5) + "b" (1)   -> offsets 0,5,6
    # chunk 1: ""      (0) + 16 chars  -> offsets 0,0,16
    _assert_int_list(
        _i32_offsets(dup.chunks()[0].column_at(0)), [0, 5, 6], "copy c0 offsets"
    )
    _assert_int_list(
        _i32_offsets(dup.chunks()[1].column_at(0)), [0, 0, 16], "copy c1 offsets"
    )
    _assert_int_list(
        _i32_offsets(sh.chunks()[0].column_at(0)), [0, 5, 6], "share c0 offsets"
    )
    _assert_int_list(
        _i32_offsets(sh.chunks()[1].column_at(0)), [0, 0, 16], "share c1 offsets"
    )
    var got = _str_values(dup.chunks()[1].column_at(0))
    assert_equal(len(got), 2, "copy c1 value count")
    assert_equal(got[0], String(""), "copy c1 value 0 is the empty string")
    assert_equal(got[1], String("gamma-long-value"), "copy c1 value 1")
    print("  ok")


def _share_then_drop_source() raises -> Table:
    """Build a table as a LOCAL, share it, return ONLY the share. The source
    drops on return -- the Arc must keep the regions alive."""
    var src = _three_chunk_i64()
    var sh = share_table(src)
    return sh^


def test_share_table_survives_source_destruction() raises:
    print("test_share_table_survives_source_destruction")
    var sh = _share_then_drop_source()
    _assert_three_chunk_shape_and_values(sh, "share-after-source-drop")
    print("  ok")


def test_share_table_zero_chunks_keeps_the_schema() raises:
    print("test_share_table_zero_chunks_keeps_the_schema")
    var src = _zero_chunk_i64()
    var sh = share_table(src)
    assert_equal(sh.num_chunks(), 0, "zero chunks stay zero")
    assert_equal(sh.num_rows(), 0, "zero rows")
    assert_equal(sh.num_columns(), 2, "the SCHEMA's column count survives")
    assert_equal(sh.schema().field_name(0), String("a"), "field 0 name")
    assert_equal(sh.schema().field_name(1), String("b"), "field 1 name")
    print("  ok")


def main() raises:
    test_copy_table_preserves_chunking_order_values_and_schema()
    test_copy_table_buffers_are_independent_of_the_source()
    test_copy_table_survives_source_destruction()
    test_copy_table_zero_chunks_keeps_the_schema()
    test_copy_table_one_chunk_is_still_a_copy()
    test_share_table_aliases_the_source_buffers()
    test_share_table_reads_identically_to_copy_table()
    test_both_primitives_preserve_string_offsets_per_chunk()
    test_share_table_survives_source_destruction()
    test_share_table_zero_chunks_keeps_the_schema()
    print("All copy_table / share_table tests passed!")
