# =============================================================================
# OP_JOIN_PROBE's LEFT, RIGHT, FULL, SEMI, ANTI and CROSS kinds, by themselves
# =============================================================================
#
# A probe is made from a spec and the build rows, fed `Morsel`s and read back,
# as `test_hash_probe` does for INNER. Rows are compared as sorted text rows,
# a NULL cell shown as `<null>`; a schema is compared as its column names,
# each followed by `?` when the field is nullable. The probe side of most tests
# is k (INT64, nullable) = 1, 2, 2, NULL, 5 with payload v = 0 .. 4; the build
# side is bk (INT64, nullable) = 1, 2, 2, 7, NULL with payload bv = 0 .. 4. What
# these tests prove:
#
#   test_left_emits_pairs_and_each_unmatched_probe_row_once_padded
#       the INNER pairs, a probe row with two partners once per partner, and a
#       probe row with no partner or a NULL key once with NULL build columns;
#       the build columns are nullable, the probe ones as they were.
#   test_left_over_an_empty_build_side_pads_every_probe_row
#       every probe row once, build columns NULL.
#   test_semi_emits_each_matched_probe_row_once_with_probe_columns_only
#       a probe row with three partners once; unmatched and NULL-key rows
#       dropped; the output columns are the probe's.
#   test_semi_returns_a_morsel_whole_when_every_row_matches
#       all rows, in the probe's columns.
#   test_semi_over_a_morsel_with_no_match_is_filtered_empty
#       FILTERED_EMPTY.
#   test_anti_emits_unmatched_and_null_key_probe_rows_only
#       the rows with no partner and the NULL-key rows, probe columns only.
#   test_anti_over_an_empty_build_side_keeps_every_row
#       every probe row.
#   test_anti_over_a_morsel_where_every_row_matches_is_filtered_empty
#       FILTERED_EMPTY.
#   test_right_emits_only_matched_pairs_per_morsel_with_nullable_probe_columns
#       the INNER pairs, no padding; the probe columns nullable.
#   test_right_tail_is_the_build_rows_no_worker_matched
#       two probes of one shared part, each given one morsel: the tail is the
#       build rows neither matched (a NULL-key build row included), the probe
#       columns NULL, in the output schema of a morsel.
#   test_right_tail_splits_into_batches_of_at_most_the_chunk_in_build_order
#       with a chunk of 2, batches of 2, 2 and 1 rows in build row order.
#   test_right_tail_without_any_probed_morsel_is_every_build_row
#       a probe that never saw a morsel owes every build row.
#   test_full_pads_both_sides_and_owes_the_unmatched_build_rows
#       LEFT's rows per morsel, then the tail; every column nullable.
#   test_kinds_that_owe_no_tail_have_none
#       INNER, LEFT, SEMI, ANTI and CROSS: has_tail is False and the tail is
#       empty; RIGHT and FULL: has_tail is True.
#   test_cross_emits_every_pair_of_probe_and_build_rows
#       a spec with no key lists gives every pair, NEED_MORE_INPUT.
#   test_cross_over_an_empty_build_side_is_filtered_empty
#       FILTERED_EMPTY.
#   test_cross_with_a_build_side_over_half_a_chunk_emits_one_probe_row_per_chunk
#       a build side of 32769 rows and a morsel of 3 rows give HAVE_MORE_OUTPUT
#       twice, then NEED_MORE_INPUT, each chunk 32769 rows holding one probe
#       row, the next chunk the next one.
#   test_cross_with_a_small_build_side_emits_one_chunk
#       a build side of 4 rows and a morsel of 5 give 20 rows in one call.
#   test_cross_with_a_key_is_refused
#       the exact refusal.
#   test_a_join_type_nobody_serves_is_refused
#       type 9 is refused by exact message.
#   test_a_masked_left_morsel_joins_only_its_selected_rows
#       the unselected rows are neither matched nor padded.
#   test_a_masked_anti_morsel_keeps_only_unmatched_selected_rows
#       the unselected rows are not kept.
#   test_join_output_schema_per_kind
#       SEMI gives the probe schema; RIGHT the probe columns nullable; LEFT
#       the build columns nullable; a build name the probe uses gets `_right`.
#   test_metrics_of_a_non_inner_probe_are_empty
#       no metrics before or after a morsel.
#   test_a_reserved_probe_key_is_refused_by_a_left_probe
#       JOIN_KEY_RESERVED by exact message.
#   test_a_reserved_timestamp_or_date64_key_is_refused
#       a TIMESTAMP_US build key and a DATE64 probe key holding the reserved
#       value are refused like an INT64 one, by exact message.

from std.builtin.swap import swap
from std.testing import TestSuite, assert_equal, assert_true

from arrow.arrow_types import ArrowType
from arrow.boolean_array import BooleanArray
from arrow.column import Column
from arrow.primitive_array import PrimitiveArray
from arrow.schema import (
    Field,
    RecordBatch,
    RecordBatchBuilder,
    Schema,
    SchemaBuilder,
)
from column_kernels.compiler_helpers import empty_batch_like_schema
from morsel.morsel import Morsel
from physical_plan.physical_plan import MorselOp
from pipeline_exec.join_harness import key_names, rows_of
from pipeline_exec.op_hash_probe import (
    HashProbeOp,
    HashProbeShared,
    JOIN_KEY_RESERVED,
    join_output_schema,
)
from plan_ir.logical_plan import (
    JOIN_ANTI,
    JOIN_CROSS,
    JOIN_FULL,
    JOIN_INNER,
    JOIN_LEFT,
    JOIN_RIGHT,
    JOIN_SEMI,
)

comptime RESERVED = 9221120237041090561
"""The INT64 value the join kernel keeps for a NULL key."""

comptime NULL = "<null>"


def _keys_batch(
    key: String,
    payload: String,
    values: List[Int],
    nulls: List[Bool],
    key_type: ArrowType = ArrowType.INT64,
) raises -> RecordBatch:
    """Rows of a key column `key` (nullable, int64 storage, of `key_type`) and
    a non-nullable INT64 `payload` holding the row number."""
    var rows = len(values)
    var k = PrimitiveArray[DType.int64].allocate_nullable(rows)
    var p = PrimitiveArray[DType.int64].allocate(rows)
    for i in range(rows):
        k.set(i, Int64(values[i]))
        if nulls[i]:
            k._set_null(i)
        p.set(i, Int64(i))
    var sb = SchemaBuilder()
    var rb = RecordBatchBuilder()
    sb.add_field(Field(key, key_type, True))
    rb.add_column(
        Column.from_primitive_with_arrow_type[DType.int64](k^, key_type)
    )
    sb.add_field(Field(payload, ArrowType.INT64, False))
    rb.add_column(Column.from_primitive[DType.int64](p^))
    return rb.build(sb.build())


def _probe() raises -> RecordBatch:
    """k = 1, 2, 2, NULL, 5; v = 0 .. 4."""
    return _keys_batch(
        "k", "v", [1, 2, 2, 0, 5], [False, False, False, True, False]
    )


def _build() raises -> RecordBatch:
    """bk = 1, 2, 2, 7, NULL; bv = 0 .. 4."""
    return _keys_batch(
        "bk", "bv", [1, 2, 2, 7, 0], [False, False, False, False, True]
    )


def _shared(
    join_type: UInt8, var build: RecordBatch
) raises -> HashProbeShared:
    """A shared part over `build`, probing k against bk (no key for CROSS)."""
    var spec: MorselOp
    if join_type == JOIN_CROSS:
        spec = MorselOp.join_probe(
            1, List[String](), List[String](), join_type
        )
    else:
        spec = MorselOp.join_probe(1, key_names("k"), key_names("bk"), join_type)
    return HashProbeShared(spec, build^)


def _sorted(var rows: List[String]) -> List[String]:
    sort(rows)
    return rows^


def _shape(ref schema: Schema) raises -> String:
    """The column names of `schema`, comma separated, each followed by `?`
    when the field is nullable."""
    var out = String("")
    for i in range(schema.num_columns()):
        if i > 0:
            out += ","
        out += schema.field_name(i)
        if schema.field_at(i).nullable:
            out += "?"
    return out^


def _equal_rows(got: List[String], want: List[String]) raises:
    assert_equal(len(got), len(want))
    for i in range(len(want)):
        assert_equal(got[i], want[i])


def _run(mut op: HashProbeOp, var batch: RecordBatch) raises -> List[String]:
    """The sorted rows `op` gives for one morsel of `batch`; none for a morsel
    it reports FILTERED_EMPTY."""
    var m = Morsel(batch^, 0, 0)
    var rc = op.execute(m)
    if rc.is_filtered_empty():
        return List[String]()
    assert_true(rc.is_need_more_input())
    return rows_of(m.batch)


def _empty_build() raises -> RecordBatch:
    var schema = _build().schema.copy()
    return empty_batch_like_schema(schema)


def _masked(var batch: RecordBatch, keep: List[Bool]) raises -> RecordBatch:
    var mask = BooleanArray.allocate(len(keep))
    for i in range(len(keep)):
        mask.set(i, keep[i])
    batch.set_selection_mask(mask^)
    return batch^


# ---- LEFT ----------------------------------------------------------------------


def test_left_emits_pairs_and_each_unmatched_probe_row_once_padded() raises:
    var shared = _shared(JOIN_LEFT, _build())
    var op = shared.make()
    var m = Morsel(_probe(), 0, 0)
    assert_true(op.execute(m).is_need_more_input())
    _equal_rows(
        rows_of(m.batch),
        _sorted(
            [
                "1|0|1|0",
                "2|1|2|1",
                "2|1|2|2",
                "2|2|2|1",
                "2|2|2|2",
                String(NULL) + "|3|" + NULL + "|" + NULL,
                "5|4|" + String(NULL) + "|" + NULL,
            ]
        ),
    )
    assert_equal(_shape(m.batch.schema), "k?,v,bk?,bv?")
    var declared = shared.output_schema(_probe().schema)
    assert_equal(_shape(declared), "k?,v,bk?,bv?")


def test_left_over_an_empty_build_side_pads_every_probe_row() raises:
    var shared = _shared(JOIN_LEFT, _empty_build())
    var op = shared.make()
    var got = _run(op, _probe())
    var pad = String("|") + NULL + "|" + NULL
    _equal_rows(
        got,
        _sorted(
            [
                "1|0" + pad,
                "2|1" + pad,
                "2|2" + pad,
                String(NULL) + "|3" + pad,
                "5|4" + pad,
            ]
        ),
    )


# ---- SEMI and ANTI -------------------------------------------------------------


def test_semi_emits_each_matched_probe_row_once_with_probe_columns_only() raises:
    # Build key 4 appears three times; the probe row of key 4 still counts once.
    var build = _keys_batch(
        "bk", "bv", [4, 4, 4, 1, 0], [False, False, False, False, True]
    )
    var shared = _shared(JOIN_SEMI, build^)
    var op = shared.make()
    var m = Morsel(
        _keys_batch("k", "v", [4, 9, 1, 0, 4], [False, False, False, True, False]),
        0,
        0,
    )
    assert_true(op.execute(m).is_need_more_input())
    _equal_rows(rows_of(m.batch), _sorted(["4|0", "1|2", "4|4"]))
    assert_equal(_shape(m.batch.schema), "k?,v")


def test_semi_returns_a_morsel_whole_when_every_row_matches() raises:
    var shared = _shared(JOIN_SEMI, _build())
    var op = shared.make()
    var m = Morsel(
        _keys_batch("k", "v", [1, 2, 2], [False, False, False]), 0, 0
    )
    assert_true(op.execute(m).is_need_more_input())
    _equal_rows(rows_of(m.batch), _sorted(["1|0", "2|1", "2|2"]))
    assert_equal(_shape(m.batch.schema), "k?,v")


def test_semi_over_a_morsel_with_no_match_is_filtered_empty() raises:
    var shared = _shared(JOIN_SEMI, _build())
    var op = shared.make()
    var m = Morsel(_keys_batch("k", "v", [5, 6, 0], [False, False, True]), 0, 0)
    assert_true(op.execute(m).is_filtered_empty())


def test_anti_emits_unmatched_and_null_key_probe_rows_only() raises:
    var shared = _shared(JOIN_ANTI, _build())
    var op = shared.make()
    var m = Morsel(_probe(), 0, 0)
    assert_true(op.execute(m).is_need_more_input())
    _equal_rows(
        rows_of(m.batch), _sorted([String(NULL) + "|3", "5|4"])
    )
    assert_equal(_shape(m.batch.schema), "k?,v")


def test_anti_over_an_empty_build_side_keeps_every_row() raises:
    var shared = _shared(JOIN_ANTI, _empty_build())
    var op = shared.make()
    _equal_rows(
        _run(op, _probe()),
        _sorted(["1|0", "2|1", "2|2", String(NULL) + "|3", "5|4"]),
    )


def test_anti_over_a_morsel_where_every_row_matches_is_filtered_empty() raises:
    var shared = _shared(JOIN_ANTI, _build())
    var op = shared.make()
    var m = Morsel(_keys_batch("k", "v", [1, 2], [False, False]), 0, 0)
    assert_true(op.execute(m).is_filtered_empty())


# ---- RIGHT and FULL ------------------------------------------------------------


def test_right_emits_only_matched_pairs_per_morsel_with_nullable_probe_columns() raises:
    var shared = _shared(JOIN_RIGHT, _build())
    var op = shared.make()
    var m = Morsel(_probe(), 0, 0)
    assert_true(op.execute(m).is_need_more_input())
    _equal_rows(
        rows_of(m.batch),
        _sorted(
            ["1|0|1|0", "2|1|2|1", "2|1|2|2", "2|2|2|1", "2|2|2|2"]
        ),
    )
    assert_equal(_shape(m.batch.schema), "k?,v?,bk?,bv")
    assert_true(shared.has_tail())


def test_right_tail_is_the_build_rows_no_worker_matched() raises:
    var shared = _shared(JOIN_RIGHT, _build())
    var one = shared.make()
    var two = shared.make()
    # Worker one meets build row 0, worker two build rows 1 and 2.
    _ = _run(one, _keys_batch("k", "v", [1], [False]))
    _ = _run(two, _keys_batch("k", "v", [2, 5], [False, False]))
    var schema = _probe().schema.copy()
    var tail = shared.unmatched_build_rows(schema, 100)
    assert_equal(len(tail), 1)
    _equal_rows(
        rows_of(tail[0]),
        _sorted(
            [
                String(NULL) + "|" + NULL + "|7|3",
                String(NULL) + "|" + NULL + "|" + NULL + "|4",
            ]
        ),
    )
    assert_equal(_shape(tail[0].schema), "k?,v?,bk?,bv")
    assert_equal(_shape(tail[0].schema), _shape(shared.output_schema(schema)))


def test_right_tail_splits_into_batches_of_at_most_the_chunk_in_build_order() raises:
    var shared = _shared(JOIN_RIGHT, _build())
    var schema = _probe().schema.copy()
    var tail = shared.unmatched_build_rows(schema, 2)
    assert_equal(len(tail), 3)
    assert_equal(tail[0].num_rows(), 2)
    assert_equal(tail[1].num_rows(), 2)
    assert_equal(tail[2].num_rows(), 1)
    var pad = String(NULL) + "|" + NULL + "|"
    _equal_rows(rows_of(tail[0]), _sorted([pad + "1|0", pad + "2|1"]))
    _equal_rows(rows_of(tail[1]), _sorted([pad + "2|2", pad + "7|3"]))
    _equal_rows(rows_of(tail[2]), [pad + NULL + "|4"])


def test_right_tail_without_any_probed_morsel_is_every_build_row() raises:
    var shared = _shared(JOIN_RIGHT, _build())
    var schema = _probe().schema.copy()
    var tail = shared.unmatched_build_rows(schema, 100)
    assert_equal(len(tail), 1)
    assert_equal(tail[0].num_rows(), 5)


def test_full_pads_both_sides_and_owes_the_unmatched_build_rows() raises:
    var shared = _shared(JOIN_FULL, _build())
    var op = shared.make()
    var m = Morsel(_probe(), 0, 0)
    assert_true(op.execute(m).is_need_more_input())
    var pad = String("|") + NULL + "|" + NULL
    _equal_rows(
        rows_of(m.batch),
        _sorted(
            [
                "1|0|1|0",
                "2|1|2|1",
                "2|1|2|2",
                "2|2|2|1",
                "2|2|2|2",
                String(NULL) + "|3" + pad,
                "5|4" + pad,
            ]
        ),
    )
    assert_equal(_shape(m.batch.schema), "k?,v?,bk?,bv?")
    assert_true(shared.has_tail())
    var schema = _probe().schema.copy()
    var tail = shared.unmatched_build_rows(schema, 100)
    assert_equal(len(tail), 1)
    _equal_rows(
        rows_of(tail[0]),
        _sorted(
            [
                String(NULL) + "|" + NULL + "|7|3",
                String(NULL) + "|" + NULL + "|" + NULL + "|4",
            ]
        ),
    )
    assert_equal(_shape(tail[0].schema), "k?,v?,bk?,bv?")


def test_kinds_that_owe_no_tail_have_none() raises:
    var schema = _probe().schema.copy()
    var types = List[UInt8]()
    types.append(JOIN_INNER)
    types.append(JOIN_LEFT)
    types.append(JOIN_SEMI)
    types.append(JOIN_ANTI)
    types.append(JOIN_CROSS)
    for i in range(len(types)):
        var shared = _shared(types[i], _build())
        assert_true(not shared.has_tail())
        assert_equal(len(shared.unmatched_build_rows(schema, 10)), 0)
        assert_equal(Int(shared.join_type()), Int(types[i]))
    assert_true(_shared(JOIN_RIGHT, _build()).has_tail())
    assert_true(_shared(JOIN_FULL, _build()).has_tail())


# ---- CROSS ---------------------------------------------------------------------


def test_cross_emits_every_pair_of_probe_and_build_rows() raises:
    var shared = _shared(
        JOIN_CROSS,
        _keys_batch("bk", "bv", [10, 20, 30], [False, False, False]),
    )
    var op = shared.make()
    var m = Morsel(_keys_batch("k", "v", [1, 2], [False, False]), 0, 0)
    assert_true(op.execute(m).is_need_more_input())
    _equal_rows(
        rows_of(m.batch),
        _sorted(
            [
                "1|0|10|0",
                "1|0|20|1",
                "1|0|30|2",
                "2|1|10|0",
                "2|1|20|1",
                "2|1|30|2",
            ]
        ),
    )
    assert_equal(_shape(m.batch.schema), "k?,v,bk?,bv")


def test_cross_over_an_empty_build_side_is_filtered_empty() raises:
    var shared = _shared(JOIN_CROSS, _empty_build())
    var op = shared.make()
    var m = Morsel(_probe(), 0, 0)
    assert_true(op.execute(m).is_filtered_empty())


def _int_at(ref batch: RecordBatch, column: Int, row: Int) raises -> Int:
    ref col = batch.column_at(column)
    return Int(col.as_primitive[DType.int64]().get(row))


def test_cross_with_a_build_side_over_half_a_chunk_emits_one_probe_row_per_chunk() raises:
    var n = 32769
    var shared = _shared(
        JOIN_CROSS,
        _keys_batch(
            "bk", "bv", List[Int](length=n, fill=0), List[Bool](length=n, fill=False)
        ),
    )
    var op = shared.make()
    var m = Morsel(
        _keys_batch("k", "v", [10, 11, 12], [False, False, False]), 0, 0
    )
    for chunk in range(3):
        var rc = op.execute(m)
        if chunk < 2:
            assert_true(rc.is_have_more_output())
        else:
            assert_true(rc.is_need_more_input())
        assert_equal(m.batch.num_rows(), n)
        assert_equal(_int_at(m.batch, 0, 0), 10 + chunk)
        assert_equal(_int_at(m.batch, 1, 0), chunk)
        assert_equal(_int_at(m.batch, 0, n - 1), 10 + chunk)
        assert_equal(_int_at(m.batch, 1, n - 1), chunk)
        assert_equal(_int_at(m.batch, 3, 0), 0)
        assert_equal(_int_at(m.batch, 3, n - 1), n - 1)
        if chunk < 2:
            var spent = RecordBatch()
            swap(m.batch, spent)


def test_cross_with_a_small_build_side_emits_one_chunk() raises:
    var shared = _shared(
        JOIN_CROSS,
        _keys_batch("bk", "bv", [1, 2, 3, 4], [False, False, False, False]),
    )
    var op = shared.make()
    var m = Morsel(
        _keys_batch("k", "v", [1, 2, 3, 4, 5], [False, False, False, False, False]),
        0,
        0,
    )
    assert_true(op.execute(m).is_need_more_input())
    assert_equal(m.batch.num_rows(), 20)


# ---- refusals ------------------------------------------------------------------


def _refusal_of(var spec: MorselOp) raises -> String:
    var failure = String("")
    try:
        _ = HashProbeShared(spec, _build())
    except e:
        failure = String(e)
    return failure^


def test_cross_with_a_key_is_refused() raises:
    var spec = MorselOp.join_probe(
        1, key_names("k"), key_names("bk"), JOIN_CROSS
    )
    assert_equal(
        _refusal_of(spec^),
        "pipeline_exec: OP_JOIN_PROBE refuses a CROSS join with 1 probe keys"
        " and 1 build keys; a CROSS join has none",
    )


def test_a_join_type_nobody_serves_is_refused() raises:
    var spec = MorselOp.join_probe(
        1, key_names("k"), key_names("bk"), UInt8(9)
    )
    assert_equal(
        _refusal_of(spec^),
        "pipeline_exec: OP_JOIN_PROBE refuses join type 9; INNER, LEFT,"
        " RIGHT, FULL, SEMI, ANTI and CROSS are served",
    )


# ---- a masked morsel -------------------------------------------------------------


def test_a_masked_left_morsel_joins_only_its_selected_rows() raises:
    var shared = _shared(JOIN_LEFT, _build())
    var op = shared.make()
    var batch = _masked(
        _keys_batch("k", "v", [1, 2, 5, 1], [False, False, False, False]),
        [True, False, True, False],
    )
    _equal_rows(
        _run(op, batch^),
        _sorted(["1|0|1|0", "5|2|" + String(NULL) + "|" + NULL]),
    )


def test_a_masked_anti_morsel_keeps_only_unmatched_selected_rows() raises:
    var shared = _shared(JOIN_ANTI, _build())
    var op = shared.make()
    var batch = _masked(
        _keys_batch("k", "v", [1, 6, 5, 7], [False, False, False, False]),
        [True, False, True, False],
    )
    _equal_rows(_run(op, batch^), ["5|2"])


# ---- schemas and metrics -----------------------------------------------------------


def test_join_output_schema_per_kind() raises:
    var probe = _keys_batch("k", "v", [1], [False]).schema.copy()
    var build = _keys_batch("k", "bv", [1], [False]).schema.copy()
    assert_equal(_shape(join_output_schema(JOIN_SEMI, probe, build)), "k?,v")
    assert_equal(_shape(join_output_schema(JOIN_ANTI, probe, build)), "k?,v")
    assert_equal(
        _shape(join_output_schema(JOIN_INNER, probe, build)), "k?,v,k_right?,bv"
    )
    assert_equal(
        _shape(join_output_schema(JOIN_RIGHT, probe, build)),
        "k?,v?,k_right?,bv",
    )
    assert_equal(
        _shape(join_output_schema(JOIN_LEFT, probe, build)),
        "k?,v,k_right?,bv?",
    )
    assert_equal(
        _shape(join_output_schema(JOIN_FULL, probe, build)),
        "k?,v?,k_right?,bv?",
    )


def test_metrics_of_a_non_inner_probe_are_empty() raises:
    var shared = _shared(JOIN_LEFT, _build())
    var op = shared.make()
    assert_equal(op.metrics_snapshot().count(), 0)
    var m = Morsel(_probe(), 0, 0)
    _ = op.execute(m)
    assert_equal(op.metrics_snapshot().count(), 0)


def test_a_reserved_probe_key_is_refused_by_a_left_probe() raises:
    var shared = _shared(JOIN_LEFT, _build())
    var op = shared.make()
    var m = Morsel(
        _keys_batch("k", "v", [1, RESERVED], [False, False]), 0, 0
    )
    var failure = String("")
    try:
        _ = op.execute(m)
    except e:
        failure = String(e)
    assert_equal(
        failure,
        String(JOIN_KEY_RESERVED)
        + ": the probe key column 'k' holds 9221120237041090561, the value"
        " the join kernel reserves for a NULL key",
    )


def test_a_reserved_timestamp_or_date64_key_is_refused() raises:
    var failure = String("")
    try:
        _ = _shared(
            JOIN_INNER,
            _keys_batch(
                "bk", "bv", [RESERVED], [False], ArrowType.TIMESTAMP_US
            ),
        )
    except e:
        failure = String(e)
    assert_equal(
        failure,
        String(JOIN_KEY_RESERVED)
        + ": the build key column 'bk' holds 9221120237041090561, the value"
        " the join kernel reserves for a NULL key",
    )
    var shared = _shared(
        JOIN_LEFT, _keys_batch("bk", "bv", [1], [False], ArrowType.DATE64)
    )
    var op = shared.make()
    var m = Morsel(
        _keys_batch("k", "v", [RESERVED], [False], ArrowType.DATE64), 0, 0
    )
    failure = String("")
    try:
        _ = op.execute(m)
    except e:
        failure = String(e)
    assert_equal(
        failure,
        String(JOIN_KEY_RESERVED)
        + ": the probe key column 'k' holds 9221120237041090561, the value"
        " the join kernel reserves for a NULL key",
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
