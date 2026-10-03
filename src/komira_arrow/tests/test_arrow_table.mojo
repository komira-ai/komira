# =============================================================================
# Tests for `Table` -- ONE result object that is CHUNKED INSIDE
# =============================================================================
#
# ⭐ WHY THIS FILE TESTS THE PRIMITIVE DIRECTLY, AND WHY THAT IS THE POINT.
# A segmented join only produces several chunks for a caller that declared it
# can take chunks (`materialize_join.materialize_parquet_join`'s
# `allow_segments`, passed as `chunk_budget_bytes > 0`). So the multi-chunk
# behaviour is reachable end-to-end ONLY through `materialize_plan_chunked`,
# and an end-to-end join test taken through the ordinary terminal exercises
# exactly one chunk. Every assertion below drives `Table` itself, at both
# chunk counts, with no gate and no route involved.
#
# WHAT IS PINNED HERE
#   1. `from_batch` is the ONE-CHUNK table and preserves rows/cols/schema.
#   2. `from_chunks` SUMS rows across chunks and keeps the chunk ORDER.
#   3. `from_chunks` REFUSES a chunk whose column COUNT disagrees with the
#      schema -- the invariant that makes `num_rows()` a plain sum.
#   3b. `from_chunks` REFUSES a chunk whose column TYPE describes a different
#      BUFFER LAYOUT than the table schema (`large_string` under `string`),
#      and ADMITS a same-layout relabel or a `NULL` tag. ⚠ ITEM 3 ALONE DOES
#      NOT stop `RecordBatch._ensure_column_type` silently rewriting a
#      column's type, and that accessor guard cannot: it compares a Column with
#      ITS OWN batch schema, which lockstep promotion has already widened to
#      agree. See the block above those tests.
#   3c. `from_chunks` REFUSES two CHUNKS that describe different buffer
#      layouts FROM EACH OTHER when the table schema's own layout class is
#      UNKNOWN and so cannot adjudicate between them. ⚠ ITEM 3b DOES NOT COVER
#      THIS AND CANNOT: its comparison is `layouts_conflict`, which is False
#      against an unknown side BY CONSTRUCTION, so under a `NULL` table field a
#      `string` chunk and a `large_string` chunk BOTH pass it. A
#      chunked-by-default engine makes a NULL-typed output column an ordinary
#      shape rather than a rare repair.
#   4. `num_columns()` is answerable on a table with ZERO chunks, because it
#      reads the SCHEMA -- "an empty result still has a schema", the property
#      whose absence makes a downstream Project raise
#      `Schema.column_index: no field named '<k>'` on disjoint key domains.
#   5. `into_single_batch()` ASSERTS on >1 chunk instead of concatenating.
#      ⛔ THIS IS THE LOAD-BEARING ONE. A silent concat there would convert
#      every routing mistake into a slow CORRECT answer -- i.e. it would give
#      back exactly the stitch this whole type exists to remove, and
#      nothing would ever go red to say so.
#   6. `take_chunks()` leaves the table EMPTY and re-initialised, not
#      moved-from -- it is a `mut self` method, so the table stays observable.
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.large_string_array import LargeStringArray
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch, RecordBatchBuilder
from komira_arrow.schema import Field, Schema, SchemaBuilder
from komira_arrow.string_array import StringArray
from komira_arrow.table import Table


def _i64_batch(var vals: List[Scalar[DType.int64]]) raises -> RecordBatch:
    var arr = PrimitiveArray[DType.int64].from_list(vals^)
    var col = Column.from_primitive[DType.int64](arr^)
    var schema = Schema.from_fields_1(Field("v", DType.int64, True))
    return RecordBatch.from_typed_columns_1(schema^, col^)


def _i64_schema() raises -> Schema:
    return Schema.from_fields_1(Field("v", DType.int64, True))


def test_from_batch_is_one_chunk() raises:
    """`from_batch` wraps without copying and reports the batch's own shape."""
    print("test_from_batch_is_one_chunk...")
    var vals = List[Scalar[DType.int64]](capacity=3)
    vals.append(Int64(1))
    vals.append(Int64(2))
    vals.append(Int64(3))
    var t = Table.from_batch(_i64_batch(vals^))
    assert_equal(t.num_chunks(), 1)
    assert_equal(t.num_rows(), 3)
    assert_equal(t.num_columns(), 1)
    assert_equal(t.schema().num_columns(), 1)
    print("  ok")


def test_from_chunks_sums_rows_and_keeps_order() raises:
    """Rows are the SUM across chunks, and the chunk sequence is in order.

    Order is the half a row-count check cannot see: a segmented join must
    produce the same rows IN THE SAME ORDER as the concatenated form, so the
    sequence's order is part of the contract, not an incidental.
    """
    print("test_from_chunks_sums_rows_and_keeps_order...")
    var chunks = List[RecordBatch]()
    var a = List[Scalar[DType.int64]](capacity=2)
    a.append(Int64(10))
    a.append(Int64(11))
    var b = List[Scalar[DType.int64]](capacity=3)
    b.append(Int64(20))
    b.append(Int64(21))
    b.append(Int64(22))
    var c = List[Scalar[DType.int64]](capacity=1)
    c.append(Int64(30))
    chunks.append(_i64_batch(a^))
    chunks.append(_i64_batch(b^))
    chunks.append(_i64_batch(c^))
    var t = Table.from_chunks(chunks^, _i64_schema())
    assert_equal(t.num_chunks(), 3)
    assert_equal(t.num_rows(), 6)
    assert_equal(t.num_columns(), 1)
    # Read the VALUES back through `chunks()` and assert the concatenation
    # order, element by element -- 10,11,20,21,22,30.
    var want = List[Int](capacity=6)
    want.append(10)
    want.append(11)
    want.append(20)
    want.append(21)
    want.append(22)
    want.append(30)
    var at = 0
    ref cs = t.chunks()
    for ci in range(len(cs)):
        var arr = cs[ci].column_as_primitive_int64(0)
        for r in range(cs[ci].num_rows()):
            assert_equal(Int(arr.get(r)), want[at])
            at += 1
    assert_equal(at, 6)
    print("  ok")


def test_from_chunks_refuses_column_count_mismatch() raises:
    """A chunk that disagrees with the schema is an ERROR, not a tolerated shape.

    Without this, `RecordBatch._ensure_column_type` would silently REWRITE the
    column's `arrow_type` to the schema's and the disagreement would surface as
    a wrong VALUE with no raise anywhere.
    """
    print("test_from_chunks_refuses_column_count_mismatch...")
    var chunks = List[RecordBatch]()
    var a = List[Scalar[DType.int64]](capacity=2)
    a.append(Int64(1))
    a.append(Int64(2))
    chunks.append(_i64_batch(a^))
    chunks.append(RecordBatch.count_only(5))  # 0 columns, 5 rows
    var raised = False
    try:
        var t = Table.from_chunks(chunks^, _i64_schema())
        _ = t^
    except e:
        raised = True
        assert_true("every chunk must carry the same schema" in String(e))
    assert_true(raised, "from_chunks must refuse a 0-column chunk under a 1-column schema")
    print("  ok")


def test_empty_table_still_has_a_schema() raises:
    """ZERO chunks, but `num_columns()` and `into_single_batch()` still answer.

    `RecordBatch.num_columns()` reads the PHYSICAL column count, so a
    schema-less empty result makes a downstream Project raise
    `Schema.column_index: no field named '<k>'` when the join's key domains
    happen to be disjoint. Sourcing the schema from the
    driver rather than from chunk 0 is what makes that unreachable here.
    """
    print("test_empty_table_still_has_a_schema...")
    var t = Table.from_chunks(List[RecordBatch](), _i64_schema())
    assert_equal(t.num_chunks(), 0)
    assert_equal(t.num_rows(), 0)
    assert_equal(t.num_columns(), 1)
    var rb = t^.into_single_batch()
    assert_equal(rb.num_rows(), 0)
    assert_equal(rb.num_columns(), 1)
    print("  ok")


def test_into_single_batch_asserts_instead_of_concatenating() raises:
    """⛔ THE LOAD-BEARING ONE. >1 chunk must RAISE, never silently stitch."""
    print("test_into_single_batch_asserts_instead_of_concatenating...")
    # 1 chunk: passes through, same rows.
    var one = List[Scalar[DType.int64]](capacity=3)
    one.append(Int64(7))
    one.append(Int64(8))
    one.append(Int64(9))
    var t1 = Table.from_batch(_i64_batch(one^))
    var rb1 = t1^.into_single_batch()
    assert_equal(rb1.num_rows(), 3)

    # 2 chunks: RAISES. A concat here would hand back a correct-but-slow answer
    # and no test anywhere would notice the route was wrong.
    var chunks = List[RecordBatch]()
    var a = List[Scalar[DType.int64]](capacity=1)
    a.append(Int64(1))
    var b = List[Scalar[DType.int64]](capacity=1)
    b.append(Int64(2))
    chunks.append(_i64_batch(a^))
    chunks.append(_i64_batch(b^))
    var t2 = Table.from_chunks(chunks^, _i64_schema())
    var raised = False
    try:
        var rb2 = t2^.into_single_batch()
        _ = rb2^
    except e:
        raised = True
        assert_true("2 chunks" in String(e))
        assert_true("take_chunks()" in String(e))
    assert_true(raised, "into_single_batch must REFUSE a 2-chunk table")
    print("  ok")


def test_take_chunks_leaves_the_table_empty_and_usable() raises:
    """`take_chunks` re-initialises the field; the table stays observable."""
    print("test_take_chunks_leaves_the_table_empty_and_usable...")
    var chunks = List[RecordBatch]()
    var a = List[Scalar[DType.int64]](capacity=2)
    a.append(Int64(1))
    a.append(Int64(2))
    var b = List[Scalar[DType.int64]](capacity=1)
    b.append(Int64(3))
    chunks.append(_i64_batch(a^))
    chunks.append(_i64_batch(b^))
    var t = Table.from_chunks(chunks^, _i64_schema())
    assert_equal(t.num_rows(), 3)
    var got = t.take_chunks()
    assert_equal(len(got), 2)
    assert_equal(got[0].num_rows(), 2)
    assert_equal(got[1].num_rows(), 1)
    # The table is still a live object -- empty, with its schema intact.
    assert_equal(t.num_chunks(), 0)
    assert_equal(t.num_rows(), 0)
    assert_equal(t.num_columns(), 1)
    print("  ok")


# =============================================================================
# THE TYPE INVARIANT -- chunks that disagree about BUFFER LAYOUT
# =============================================================================
#
# ⭐ WHY THESE EXIST. The module header of `table.mojo` states the invariant as
# "EVERY CHUNK SHARES ONE SCHEMA ... Enforced at construction, fail-loud". A
# `from_chunks` that compares `num_columns()` and nothing else would let a
# chunk sit under a table schema that describes a DIFFERENT buffer layout,
# with no raise anywhere.
#
# THE SHAPE THESE FIXTURES REPRODUCE IS THE ONE A PRODUCER ACTUALLY BUILDS.
# Every chunk below is INTERNALLY CONSISTENT -- its own `schema` agrees with
# its own columns -- because that is what lockstep offset-width promotion
# leaves behind: `RecordBatchBuilder.build` widens THAT BATCH's schema to
# `large_string` when the gather promoted (`record_batch.mojo`, the
# `wide_offsets_are_real` arm), while the table-level schema the driver already
# built stays `string`. So no intra-batch guard can see it: `_ensure_column_type`
# and `_reject_layout_conflict` compare a Column against ITS OWN batch schema,
# and by then those two AGREE. The divergence lives strictly BETWEEN the table
# schema and a chunk, which is the one relationship only `from_chunks` is
# positioned to check.
#
# ⚠ THE CHECK IS `layouts_conflict`, NOT `!=`, AND THE NARROWNESS IS DELIBERATE
# -- the last two tests are the negative controls that pin it there.
# =============================================================================


def _narrow_string_chunk(var vals: List[String]) raises -> RecordBatch:
    """A chunk whose column AND whose own schema say `string` (int32 offsets)."""
    var sb = SchemaBuilder()
    sb.add_field(Field("s", ArrowType.STRING, False))
    var rb = RecordBatchBuilder()
    rb.add_column(Column.from_string(StringArray.from_strings(vals^)))
    var schema = sb.build()
    return rb.build(schema^)


def _wide_string_chunk(var vals: List[String]) raises -> RecordBatch:
    """A chunk whose column AND whose own schema say `large_string` (int64).

    This is what a PROMOTED gather hands back: the column carries int64
    offsets and `build`'s lockstep arm has already widened this batch's own
    schema to match. Internally consistent, and that is the whole problem.
    """
    var sb = SchemaBuilder()
    sb.add_field(Field("s", ArrowType.LARGE_STRING, False))
    var rb = RecordBatchBuilder()
    rb.add_column(
        Column.from_large_string(LargeStringArray.from_strings(vals^))
    )
    var schema = sb.build()
    return rb.build(schema^)


def _one_field_schema(t: ArrowType) raises -> Schema:
    var sb = SchemaBuilder()
    sb.add_field(Field("s", t, False))
    return sb.build()


def _two_strings(a: String, b: String) -> List[String]:
    var out = List[String](capacity=2)
    out.append(a)
    out.append(b)
    return out^


def test_from_chunks_refuses_offset_width_divergence() raises:
    """⭐ THE DEFECT. A PROMOTED chunk under a NARROW table schema must RAISE.

    Chunk 0 gathered under 2 GiB and stayed `string`; chunk 1 promoted and came
    back `large_string`. The table schema -- the driver's own, built before any
    gather ran -- still says `string`.

    WHAT THE SILENT ACCEPT COSTS. A consumer reads `table.schema()` ONCE (the
    property the whole chunked design is built on) and then walks
    `table.chunks()`. On chunk 1 it strides an Int64 offsets buffer by 4, so
    every offset after the first is read from the high half of the previous
    entry -- garbage lengths into a valid data buffer. That is a WRONG ANSWER
    with no raise anywhere, not a crash, which is why it has to be refused at
    the seam that assembles the table.
    """
    print("test_from_chunks_refuses_offset_width_divergence...")
    var chunks = List[RecordBatch]()
    chunks.append(_narrow_string_chunk(_two_strings("alpha", "beta")))
    chunks.append(_wide_string_chunk(_two_strings("gamma", "delta")))
    var raised = False
    try:
        var t = Table.from_chunks(chunks^, _one_field_schema(ArrowType.STRING))
        _ = t^
    except e:
        raised = True
        var m = String(e)
        assert_true(
            "from_chunks" in m,
            "the error must name the seam that refused: got " + m,
        )
        assert_true(
            "chunk 1" in m,
            "the error must name WHICH chunk diverged: got " + m,
        )
        assert_true(
            "large_string" in m and "string" in m,
            "the error must name BOTH types, so the reader can tell which"
            " side promoted: got " + m,
        )
    assert_true(
        raised,
        "Table.from_chunks ACCEPTED a large_string chunk under a string table"
        " schema. A consumer reading table.schema() once and chunks() per"
        " segment then strides an Int64 offsets buffer by 4 -- a wrong answer"
        " with no raise anywhere.",
    )
    print("  ok")


def test_from_chunks_refuses_a_narrow_chunk_under_a_wide_schema() raises:
    """The REVERSE direction, which is not symmetric and must also raise.

    `RecordBatchBuilder.build` reconciles a wide COLUMN under a narrow FIELD
    (widening is safe -- every value stays representable). It deliberately does
    NOT reconcile the reverse, because narrowing the declared type of a column
    whose offsets are int32 is a claim about the buffers that is false. The
    table seam has to hold the same line, or the direction `build` refuses
    simply re-enters one frame up.
    """
    print("test_from_chunks_refuses_a_narrow_chunk_under_a_wide_schema...")
    var chunks = List[RecordBatch]()
    chunks.append(_wide_string_chunk(_two_strings("alpha", "beta")))
    chunks.append(_narrow_string_chunk(_two_strings("gamma", "delta")))
    var raised = False
    try:
        var t = Table.from_chunks(
            chunks^, _one_field_schema(ArrowType.LARGE_STRING)
        )
        _ = t^
    except e:
        raised = True
        assert_true("chunk 1" in String(e))
    assert_true(
        raised,
        "a string chunk under a large_string table schema must RAISE -- the"
        " narrowing direction is the one build() refuses, and this seam must"
        " not admit it instead",
    )
    print("  ok")


def test_from_chunks_admits_a_same_layout_relabel() raises:
    """⛔ NEGATIVE CONTROL: the check must NOT be `chunk_type != table_type`.

    `DATE32` and `INT32` are the SAME physical layout -- a 4-byte fixed-width
    values buffer -- and this tree relabels across that boundary DELIBERATELY
    (the column evaluator, the parquet decoder), exactly as
    `RecordBatch._reject_layout_conflict` documents. A guard written as a plain
    type inequality would red those paths, so the comparison is
    `layouts_conflict`, which is True only when BOTH layout classes are known
    AND differ.

    If this test goes red, the fix over-fired: it is rejecting a relabel that
    reads the same bytes.
    """
    print("test_from_chunks_admits_a_same_layout_relabel...")
    var a = List[Scalar[DType.int32]](capacity=2)
    a.append(Int32(7))
    a.append(Int32(8))
    var sb = SchemaBuilder()
    sb.add_field(Field("s", ArrowType.INT32, False))
    var rb = RecordBatchBuilder()
    rb.add_column(
        Column.from_primitive[DType.int32](
            PrimitiveArray[DType.int32].from_list(a^)
        )
    )
    var chunk_schema = sb.build()
    var chunks = List[RecordBatch]()
    chunks.append(rb.build(chunk_schema^))
    # Table schema says DATE32; the chunk says INT32. Same 4-byte layout.
    var t = Table.from_chunks(chunks^, _one_field_schema(ArrowType.DATE32))
    assert_equal(t.num_rows(), 2)
    assert_equal(t.num_chunks(), 1)
    print("  ok")


def test_from_chunks_admits_an_unknown_layout_side() raises:
    """⛔ NEGATIVE CONTROL: a `NULL` tag must stay ADMITTED.

    A zeroed `arrow_type` reading as `ArrowType.NULL` is the known
    signature of a `Column` MOVE defect. `_ensure_column_type`'s heuristic
    recovery from it must keep working, so `physical_layout_class()` returns
    `ARROW_LAYOUT_UNKNOWN` for `NULL` and `layouts_conflict` is False against
    anything. Refusing here would convert a REPAIRABLE corruption into a hard
    failure at table assembly -- strictly worse than admitting it.
    """
    print("test_from_chunks_admits_an_unknown_layout_side...")
    var vals = List[Scalar[DType.int64]](capacity=2)
    vals.append(Int64(1))
    vals.append(Int64(2))
    var chunks = List[RecordBatch]()
    chunks.append(_i64_batch(vals^))
    # Table schema says NULL -- layout not determined by the tag, so no
    # rejection may be derived from it.
    var t = Table.from_chunks(chunks^, _one_field_schema(ArrowType.NULL))
    assert_equal(t.num_rows(), 2)
    print("  ok")


# =============================================================================
# THE CROSS-CHUNK INVARIANT -- chunks that disagree with EACH OTHER
# =============================================================================
#
# ⭐ WHY THE CHUNK-vs-SCHEMA CHECK ABOVE IS NOT ENOUGH, AND WHY THAT IS A
# STRUCTURAL GAP RATHER THAN AN OVERSIGHT.
#
# `layouts_conflict` is False whenever EITHER side's layout class is unknown.
# That carve-out is deliberate and has to stay: a zeroed `arrow_type` reading
# as `ArrowType.NULL` is the `Column` MOVE defect's signature, and
# `_ensure_column_type`'s heuristic recovery from it must keep working. But the
# predicate does not care WHICH side is unknown, and when the unknown side is
# the TABLE SCHEMA the whole chunk-vs-schema comparison goes vacuous for that
# column: chunk 0 `string` passes, chunk 1 `large_string` passes, and the two
# contradict each other. A consumer that reads `table.schema()` ONCE -- which
# is the property the entire chunked design rests on -- then walks the chunks
# and strides one of them by the wrong offset width.
#
# THE FIX COMPARES THE CHUNKS TO EACH OTHER, AND ONLY WHERE THE SCHEMA CANNOT
# DECIDE. When the table type's class is KNOWN, transitivity already does the
# work (every chunk that agrees with a known class agrees with every other one
# that does), so the witness is armed ONLY for the unknown-typed columns. The
# three negative controls below are what pin that narrowness: agreeing chunks
# under a NULL schema, a NULL CHUNK column beside a typed one, and a relabel
# between chunks must all stay ADMITTED.
# =============================================================================


def _null_typed_i64_chunk(
    var vals: List[Scalar[DType.int64]]
) raises -> RecordBatch:
    """A chunk carrying int64 values under a field declared `NULL`.

    `RecordBatchBuilder.build` reconciles the schema to the column ONLY for a
    DICTIONARY column and for a real wide-offset promotion, so a primitive
    column under a `NULL` field keeps the `NULL` tag -- which is exactly the
    zeroed-tag shape the MOVE-defect carve-out exists for.
    """
    var sb = SchemaBuilder()
    sb.add_field(Field("s", ArrowType.NULL, True))
    var rb = RecordBatchBuilder()
    rb.add_column(
        Column.from_primitive[DType.int64](
            PrimitiveArray[DType.int64].from_list(vals^)
        )
    )
    var schema = sb.build()
    return rb.build(schema^)


def _i32_chunk(var vals: List[Scalar[DType.int32]], t: ArrowType) raises -> RecordBatch:
    """A 4-byte fixed-width chunk whose own schema declares `t`."""
    var sb = SchemaBuilder()
    sb.add_field(Field("s", t, False))
    var rb = RecordBatchBuilder()
    rb.add_column(
        Column.from_primitive[DType.int32](
            PrimitiveArray[DType.int32].from_list(vals^)
        )
    )
    var schema = sb.build()
    return rb.build(schema^)


def _two_i32(a: Int32, b: Int32) -> List[Scalar[DType.int32]]:
    var out = List[Scalar[DType.int32]](capacity=2)
    out.append(a)
    out.append(b)
    return out^


def _two_i64(a: Int64, b: Int64) -> List[Scalar[DType.int64]]:
    var out = List[Scalar[DType.int64]](capacity=2)
    out.append(a)
    out.append(b)
    return out^


def test_from_chunks_refuses_cross_chunk_divergence_under_an_unknown_schema() raises:
    """⭐ THE DEFECT. Two chunks of DIFFERENT offset width under a `NULL` field.

    Neither chunk conflicts with the TABLE SCHEMA -- `layouts_conflict` is
    False against `NULL` on purpose -- so the chunk-vs-schema check admits both
    while they flatly contradict each other. The table then declares one schema
    over segments whose `s` column is int32-offset in chunk 0 and int64-offset
    in chunk 1.

    Without the cross-chunk check `from_chunks` returns a 4-row table. There is no later
    seam that catches it -- `_ensure_column_type` and
    `_reject_layout_conflict` compare a Column against ITS OWN batch schema,
    and each chunk here is internally consistent.
    """
    print("test_from_chunks_refuses_cross_chunk_divergence_under_an_unknown_schema...")
    var chunks = List[RecordBatch]()
    chunks.append(_narrow_string_chunk(_two_strings("alpha", "beta")))
    chunks.append(_wide_string_chunk(_two_strings("gamma", "delta")))
    var raised = False
    try:
        var t = Table.from_chunks(chunks^, _one_field_schema(ArrowType.NULL))
        _ = t^
    except e:
        raised = True
        var m = String(e)
        assert_true(
            "from_chunks" in m,
            "the error must name the seam that refused: got " + m,
        )
        assert_true(
            "chunk 0" in m and "chunk 1" in m,
            "the error must name BOTH chunks -- the conflict is between them,"
            " not between one of them and the schema: got " + m,
        )
        assert_true(
            "large_string" in m and "string" in m,
            "the error must name both types so the reader can tell which"
            " segment promoted: got " + m,
        )
    assert_true(
        raised,
        "Table.from_chunks ACCEPTED a string chunk beside a large_string chunk"
        " because the TABLE schema said NULL. `layouts_conflict` is False"
        " against an unknown side, so the chunk-vs-schema check is vacuous for"
        " that column and the two segments were never compared to each other."
        " A consumer reading table.schema() once then strides one of them by"
        " the wrong offset width -- a wrong answer with no raise anywhere.",
    )
    print("  ok")


def test_from_chunks_admits_agreeing_chunks_under_an_unknown_schema() raises:
    """⛔ NEGATIVE CONTROL: the refusal is about DISAGREEMENT, not about NULL.

    A guard written as "more than one chunk under an unknown table type is
    unsafe" would satisfy the test above and red this one. Both chunks here are
    `string`; they agree, and the table must build.
    """
    print("test_from_chunks_admits_agreeing_chunks_under_an_unknown_schema...")
    var chunks = List[RecordBatch]()
    chunks.append(_narrow_string_chunk(_two_strings("alpha", "beta")))
    chunks.append(_narrow_string_chunk(_two_strings("gamma", "delta")))
    var t = Table.from_chunks(chunks^, _one_field_schema(ArrowType.NULL))
    assert_equal(t.num_rows(), 4)
    assert_equal(t.num_chunks(), 2)
    print("  ok")


def test_from_chunks_admits_a_null_chunk_column_beside_a_typed_one() raises:
    """⛔ NEGATIVE CONTROL: a NULL CHUNK column stays admitted, both ways.

    The MOVE-defect carve-out is about the CHUNK side of the comparison and it
    must survive the cross-chunk arm: a zeroed tag neither sets a witness nor
    is judged against one. Refusing here would convert a REPAIRABLE corruption
    into a hard failure at table assembly -- strictly worse than admitting it, and the
    reason `layouts_conflict` is conservative in the first place.

    Both orders are asserted, because a witness implementation that records the
    FIRST chunk unconditionally passes one order and reds the other.
    """
    print("test_from_chunks_admits_a_null_chunk_column_beside_a_typed_one...")
    var a = List[RecordBatch]()
    a.append(_null_typed_i64_chunk(_two_i64(Int64(1), Int64(2))))
    a.append(_narrow_string_chunk(_two_strings("gamma", "delta")))
    var t1 = Table.from_chunks(a^, _one_field_schema(ArrowType.NULL))
    assert_equal(t1.num_rows(), 4, "NULL chunk first must be admitted")

    var b = List[RecordBatch]()
    b.append(_narrow_string_chunk(_two_strings("gamma", "delta")))
    b.append(_null_typed_i64_chunk(_two_i64(Int64(1), Int64(2))))
    var t2 = Table.from_chunks(b^, _one_field_schema(ArrowType.NULL))
    assert_equal(t2.num_rows(), 4, "NULL chunk second must be admitted")
    print("  ok")


def test_from_chunks_admits_a_cross_chunk_relabel_under_an_unknown_schema() raises:
    """⛔ NEGATIVE CONTROL: the cross-chunk check is `layouts_conflict`, not `!=`.

    `DATE32` and `INT32` are the same 4-byte fixed-width layout and this tree
    relabels across that boundary deliberately. The chunk-vs-schema check
    already admits it (`test_from_chunks_admits_a_same_layout_relabel`); the
    cross-chunk arm must admit it too, or it reds the same paths one comparison
    later.
    """
    print("test_from_chunks_admits_a_cross_chunk_relabel_under_an_unknown_schema...")
    var chunks = List[RecordBatch]()
    chunks.append(_i32_chunk(_two_i32(Int32(7), Int32(8)), ArrowType.INT32))
    chunks.append(_i32_chunk(_two_i32(Int32(9), Int32(10)), ArrowType.DATE32))
    var t = Table.from_chunks(chunks^, _one_field_schema(ArrowType.NULL))
    assert_equal(t.num_rows(), 4)
    assert_equal(t.num_chunks(), 2)
    print("  ok")


def main() raises:
    test_from_batch_is_one_chunk()
    test_from_chunks_sums_rows_and_keeps_order()
    test_from_chunks_refuses_column_count_mismatch()
    test_empty_table_still_has_a_schema()
    test_into_single_batch_asserts_instead_of_concatenating()
    test_take_chunks_leaves_the_table_empty_and_usable()
    test_from_chunks_refuses_offset_width_divergence()
    test_from_chunks_refuses_a_narrow_chunk_under_a_wide_schema()
    test_from_chunks_admits_a_same_layout_relabel()
    test_from_chunks_admits_an_unknown_layout_side()
    test_from_chunks_refuses_cross_chunk_divergence_under_an_unknown_schema()
    test_from_chunks_admits_agreeing_chunks_under_an_unknown_schema()
    test_from_chunks_admits_a_null_chunk_column_beside_a_typed_one()
    test_from_chunks_admits_a_cross_chunk_relabel_under_an_unknown_schema()
    print("All Table tests passed!")
