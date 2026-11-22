# =============================================================================
# OP_JOIN_PROBE's operator, `HashProbeShared` and `HashProbeOp`, by themselves
# =============================================================================
#
# A probe is made from a spec and the build rows, fed `Morsel`s and read back,
# and every answer is compared as a multiset of rows with a nested-loop join
# written in `join_harness`, which shares no code with the kernel. What these
# tests prove:
#
#   * The shared part refuses, by exact message, an operator that is not a
#     join probe, a join type other than INNER, a residual, a late-
#     materialization column list, the sort-merge algorithm, no keys, key lists
#     of unequal length and nine keys.
#   * An INT64 key equal to the value the kernel keeps for NULL is refused by
#     name, with the column and the side, when it is on the build side and when
#     it is on the probe side; the same value under a NULL slot is not refused
#     and matches nothing.
#   * A NULL key on either side matches nothing, including a NULL slot that
#     stores 0 against a real 0 on the other side.
#   * Duplicate keys multiply: every probe row meets every build row of its key.
#   * A morsel whose rows all fail to match, and a morsel with no row, are
#     FILTERED_EMPTY.
#   * A morsel that carries a selection mask joins only its selected rows.
#   * The output is the probe columns then the build columns, and a build name
#     the probe side already uses gets the suffix `_right`.
#   * An INT32 build key meets an INT64 probe key by value; STRING keys, FLOAT64
#     keys (NaN equals NaN, -0.0 equals 0.0, NULL matches nothing) and a
#     composite of two INT64 keys join as the oracle does.
#   * A later morsel whose schema differs (an extra column, one that collides
#     with a build name) gets the output schema of its own columns.
#   * An empty build side joins nothing, and the probes of one shared part,
#     made for different workers, each answer for their own morsels.
#   * The probe's metrics are empty before its first morsel and count after.

from std.testing import TestSuite, assert_equal, assert_true

from arrow.arrow_types import ArrowType
from arrow.boolean_array import BooleanArray
from arrow.column import Column
from arrow.primitive_array import PrimitiveArray
from arrow.schema import (
    Field,
    RecordBatch,
    RecordBatchBuilder,
    SchemaBuilder,
)
from column_kernels.compiler_helpers import empty_batch_like_schema
from morsel.morsel import Morsel
from physical_plan.physical_plan import MorselOp
from pipeline_exec.join_harness import (
    customer_batch,
    expect_rows,
    expected_rows,
    float_build_batch,
    float_probe_batch,
    keep_rows,
    key_names,
    oracle_join,
    orders_batch,
    pair_build_batch,
    pair_probe_batch,
    probe_op,
    refund_batch,
    rows_of,
    sorted_rows,
    table_of,
    tag_build_batch,
    tag_probe_batch,
)
from pipeline_exec.op_hash_probe import (
    HashProbeOp,
    HashProbeShared,
    JOIN_KEY_RESERVED,
)
from pipeline_exec.plan_harness import column_names
from plan_expr.expr import Expr
from plan_expr.scalar_value import ScalarValue
from plan_ir.logical_plan import (
    JOIN_ALGO_SORT_MERGE,
    JOIN_INNER,
    JOIN_LEFT,
)

comptime RESERVED = 9221120237041090561
"""The INT64 value the join kernel keeps for a NULL key."""


def _keys_batch(
    key: String,
    payload: String,
    values: List[Int],
    nulls: List[Bool],
    extra: String = "",
) raises -> RecordBatch:
    """Rows of an INT64 key column `key` (nullable; a NULL row stores its value
    under the NULL), an INT64 `payload` holding the row number and, when
    `extra` is named, an INT64 column of that name between them holding
    row * 1000."""
    var rows = len(values)
    var k = PrimitiveArray[DType.int64].allocate_nullable(rows)
    var p = PrimitiveArray[DType.int64].allocate(rows)
    var x = PrimitiveArray[DType.int64].allocate(rows)
    for i in range(rows):
        k.set(i, Int64(values[i]))
        if nulls[i]:
            k._set_null(i)
        p.set(i, Int64(i))
        x.set(i, Int64(i * 1000))
    var sb = SchemaBuilder()
    var rb = RecordBatchBuilder()
    sb.add_field(Field(key, ArrowType.INT64, True))
    rb.add_column(Column.from_primitive[DType.int64](k^))
    if extra.byte_length() > 0:
        sb.add_field(Field(extra, ArrowType.INT64, False))
        rb.add_column(Column.from_primitive[DType.int64](x^))
    sb.add_field(Field(payload, ArrowType.INT64, False))
    rb.add_column(Column.from_primitive[DType.int64](p^))
    return rb.build(sb.build())


def _float_payload_batch() raises -> RecordBatch:
    """One row: INT64 key `k` = 1 and a FLOAT64 payload `v` = 0.5."""
    var k = PrimitiveArray[DType.int64].allocate(1)
    k.set(0, Int64(1))
    var v = PrimitiveArray[DType.float64].allocate(1)
    v.set(0, Float64(0.5))
    var sb = SchemaBuilder()
    var rb = RecordBatchBuilder()
    sb.add_field(Field("k", ArrowType.INT64, False))
    rb.add_column(Column.from_primitive[DType.int64](k^))
    sb.add_field(Field("v", ArrowType.FLOAT64, False))
    rb.add_column(Column.from_primitive[DType.float64](v^))
    return rb.build(sb.build())


def _run(mut op: HashProbeOp, var batch: RecordBatch) raises -> List[String]:
    """The sorted rows `op` gives for one morsel of `batch`; none for a morsel
    it reports FILTERED_EMPTY."""
    var m = Morsel(batch^, 0, 0)
    var rc = op.execute(m)
    if rc.is_filtered_empty():
        return List[String]()
    assert_true(rc.is_need_more_input())
    return rows_of(m.batch)


def _join(
    var probe: RecordBatch,
    var build: RecordBatch,
    probe_keys: List[String],
    build_keys: List[String],
) raises -> List[String]:
    """The sorted rows of one morsel of `probe` through a probe over `build`."""
    var spec = probe_op(1, probe_keys, build_keys)
    var shared = HashProbeShared(spec, build^)
    var op = shared.make()
    return _run(op, probe^)


def _refusal_of(var spec: MorselOp) raises -> String:
    var failure = String("")
    try:
        _ = HashProbeShared(spec, customer_batch(4))
    except e:
        failure = String(e)
    return failure^


# ---- what the shared part refuses ---------------------------------------------


def test_an_operator_that_is_not_a_join_probe_is_refused() raises:
    assert_equal(
        _refusal_of(MorselOp.limit(5)),
        "pipeline_exec: OP_JOIN_PROBE refuses an operator that is not"
        " OP_JOIN_PROBE",
    )


def test_a_join_type_other_than_inner_is_refused() raises:
    var spec = MorselOp.join_probe(
        1, key_names("o_custkey"), key_names("c_custkey"), JOIN_LEFT
    )
    assert_equal(
        _refusal_of(spec^),
        "pipeline_exec: OP_JOIN_PROBE refuses join type 1; only INNER is"
        " served",
    )


def test_a_residual_predicate_is_refused() raises:
    var spec = MorselOp.join_probe_with_residual(
        1,
        key_names("o_custkey"),
        key_names("c_custkey"),
        JOIN_INNER,
        Expr.literal(ScalarValue.from_int(1)),
        None,
    )
    assert_equal(
        _refusal_of(spec^),
        "pipeline_exec: OP_JOIN_PROBE refuses a residual predicate",
    )


def test_a_late_materialization_column_list_is_refused() raises:
    var spec = MorselOp.join_probe_projected(
        1,
        key_names("o_custkey"),
        key_names("c_custkey"),
        JOIN_INNER,
        key_names("o_id"),
    )
    assert_equal(
        _refusal_of(spec^),
        "pipeline_exec: OP_JOIN_PROBE refuses a late-materialization column"
        " list",
    )


def test_the_sort_merge_algorithm_is_refused() raises:
    var spec = MorselOp.join_probe(
        1,
        key_names("o_custkey"),
        key_names("c_custkey"),
        JOIN_INNER,
        JOIN_ALGO_SORT_MERGE,
    )
    assert_equal(
        _refusal_of(spec^),
        "pipeline_exec: OP_JOIN_PROBE refuses the sort-merge algorithm",
    )


def test_no_keys_unequal_key_lists_and_nine_keys_are_refused() raises:
    var none = MorselOp.join_probe(
        1, List[String](), List[String](), JOIN_INNER
    )
    assert_equal(
        _refusal_of(none^),
        "pipeline_exec: OP_JOIN_PROBE refuses 0 probe keys and 0 build keys;"
        " one to 8 of each, in pairs, are served",
    )
    var unequal = MorselOp.join_probe(
        1, key_names("o_id", "o_custkey"), key_names("c_custkey"), JOIN_INNER
    )
    assert_equal(
        _refusal_of(unequal^),
        "pipeline_exec: OP_JOIN_PROBE refuses 2 probe keys and 1 build keys;"
        " one to 8 of each, in pairs, are served",
    )
    var nine = List[String]()
    for i in range(9):
        nine.append(String("k") + String(i))
    var many = MorselOp.join_probe(1, nine.copy(), nine.copy(), JOIN_INNER)
    assert_equal(
        _refusal_of(many^),
        "pipeline_exec: OP_JOIN_PROBE refuses 9 probe keys and 9 build keys;"
        " one to 8 of each, in pairs, are served",
    )


# ---- the key value the kernel reserves ---------------------------------------


def test_a_reserved_build_key_is_refused_naming_column_and_side() raises:
    var spec = probe_op(1, key_names("k"), key_names("bk"))
    var build = _keys_batch("bk", "bv", [5, RESERVED], [False, False])
    var failure = String("")
    try:
        _ = HashProbeShared(spec, build^)
    except e:
        failure = String(e)
    assert_equal(
        failure,
        String(JOIN_KEY_RESERVED)
        + ": the build key column 'bk' holds 9221120237041090561, the value"
        " the join kernel reserves for a NULL key",
    )


def test_a_reserved_probe_key_is_refused_naming_column_and_side() raises:
    var spec = probe_op(1, key_names("k"), key_names("bk"))
    var shared = HashProbeShared(
        spec, _keys_batch("bk", "bv", [5, 6], [False, False])
    )
    var op = shared.make()
    var m = Morsel(
        _keys_batch("k", "v", [5, RESERVED, 6], [False, False, False]), 0, 0
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


def test_the_reserved_value_under_a_null_slot_is_not_refused_and_matches_nothing() raises:
    var got = _join(
        _keys_batch("k", "v", [5, RESERVED, 6], [False, True, False]),
        _keys_batch("bk", "bv", [RESERVED, 5, 6], [True, False, False]),
        key_names("k"),
        key_names("bk"),
    )
    var want = expected_rows(
        _keys_batch("k", "v", [5, RESERVED, 6], [False, True, False]),
        _keys_batch("bk", "bv", [RESERVED, 5, 6], [True, False, False]),
        key_names("k"),
        key_names("bk"),
    )
    assert_equal(len(want), 2)
    expect_rows(got, want, "reserved value under NULL")


# ---- matching ----------------------------------------------------------------


def test_a_null_key_matches_nothing_even_against_a_stored_zero() raises:
    # Probe row 1 and build row 0 are NULL with 0 stored under them; probe row
    # 0 and build row 1 hold a real 0.
    var got = _join(
        _keys_batch("k", "v", [0, 0, 1, 7], [False, True, False, False]),
        _keys_batch("bk", "bv", [0, 0, 1], [True, False, False]),
        key_names("k"),
        key_names("bk"),
    )
    var want = expected_rows(
        _keys_batch("k", "v", [0, 0, 1, 7], [False, True, False, False]),
        _keys_batch("bk", "bv", [0, 0, 1], [True, False, False]),
        key_names("k"),
        key_names("bk"),
    )
    assert_equal(len(want), 2)
    expect_rows(got, want, "NULL against zero")


def test_a_build_side_of_only_null_keys_joins_nothing() raises:
    var got = _join(
        _keys_batch("k", "v", [0, 1, 2], [False, False, False]),
        _keys_batch("bk", "bv", [0, 1, 2], [True, True, True]),
        key_names("k"),
        key_names("bk"),
    )
    assert_equal(len(got), 0)


def test_duplicate_keys_multiply() raises:
    var probe = _keys_batch("k", "v", [1, 1, 2, 3], [False, False, False, False])
    var build = _keys_batch(
        "bk", "bv", [1, 1, 1, 2, 9], [False, False, False, False, False]
    )
    var got = _join(
        _keys_batch("k", "v", [1, 1, 2, 3], [False, False, False, False]),
        _keys_batch(
            "bk", "bv", [1, 1, 1, 2, 9], [False, False, False, False, False]
        ),
        key_names("k"),
        key_names("bk"),
    )
    # Two probe rows of key 1 meet three build rows each, the row of key 2
    # meets one, key 3 meets none.
    assert_equal(len(got), 7)
    expect_rows(
        got, expected_rows(probe, build, key_names("k"), key_names("bk")), "dups"
    )


def test_an_unmatched_morsel_and_a_morsel_with_no_row_are_filtered_empty() raises:
    var spec = probe_op(1, key_names("o_custkey"), key_names("c_custkey"))
    var shared = HashProbeShared(spec, customer_batch(10))
    var op = shared.make()
    # Customer keys are 0 .. 9; these orders carry only 10, 11 and 12.
    var unmatched = _keys_batch("o_custkey", "o_id", [10, 11, 12], [False, False, False])
    var m = Morsel(unmatched^, 0, 0)
    assert_true(op.execute(m).is_filtered_empty())
    var schema = orders_batch(0, 1).schema.copy()
    var empty = Morsel(empty_batch_like_schema(schema), 0, 0)
    assert_true(op.execute(empty).is_filtered_empty())
    # The probe still answers a morsel that does match.
    var got = _run(op, orders_batch(0, 30))
    assert_true(len(got) > 0)


def test_a_masked_morsel_joins_only_its_selected_rows() raises:
    var batch = orders_batch(0, 40)
    var mask = BooleanArray.allocate(40)
    var keep = List[Bool]()
    for i in range(40):
        var selected = i % 3 != 1
        mask.set(i, selected)
        keep.append(selected)
    batch.set_selection_mask(mask^)
    var spec = probe_op(1, key_names("o_custkey"), key_names("c_custkey"))
    var shared = HashProbeShared(spec, customer_batch(25))
    var op = shared.make()
    var got = _run(op, batch^)
    var want = sorted_rows(
        oracle_join(
            keep_rows(table_of(orders_batch(0, 40)), keep),
            table_of(customer_batch(25)),
            key_names("o_custkey"),
            key_names("c_custkey"),
        )
    )
    assert_true(len(want) > 0)
    expect_rows(got, want, "masked morsel")


def test_a_mask_that_selects_no_row_is_filtered_empty() raises:
    var batch = orders_batch(0, 10)
    var mask = BooleanArray.allocate(10)
    for i in range(10):
        mask.set(i, False)
    batch.set_selection_mask(mask^)
    var spec = probe_op(1, key_names("o_custkey"), key_names("c_custkey"))
    var shared = HashProbeShared(spec, customer_batch(25))
    var op = shared.make()
    var m = Morsel(batch^, 0, 0)
    assert_true(op.execute(m).is_filtered_empty())


# ---- the output schema --------------------------------------------------------


def test_the_output_is_probe_columns_then_build_columns() raises:
    var spec = probe_op(1, key_names("o_custkey"), key_names("c_custkey"))
    var shared = HashProbeShared(spec, customer_batch(10))
    var op = shared.make()
    var m = Morsel(orders_batch(0, 30), 0, 0)
    _ = op.execute(m)
    var names = column_names(m.batch)
    assert_equal(len(names), 6)
    assert_equal(names[0], "o_id")
    assert_equal(names[1], "o_custkey")
    assert_equal(names[2], "o_total")
    assert_equal(names[3], "c_custkey")
    assert_equal(names[4], "c_name")
    assert_equal(names[5], "c_nation")
    assert_equal(shared.build_rows(), 10)
    var schema = orders_batch(0, 1).schema.copy()
    var declared = shared.output_schema(schema)
    assert_equal(declared.num_columns(), 6)
    assert_equal(declared.field_name(5), "c_nation")


def test_a_build_name_the_probe_uses_gets_the_suffix_right() raises:
    var spec = probe_op(1, key_names("o_id"), key_names("o_id"))
    var shared = HashProbeShared(spec, refund_batch(10))
    var op = shared.make()
    var m = Morsel(orders_batch(0, 40), 0, 0)
    assert_true(op.execute(m).is_need_more_input())
    var names = column_names(m.batch)
    assert_equal(len(names), 6)
    assert_equal(names[0], "o_id")
    assert_equal(names[1], "o_custkey")
    assert_equal(names[2], "o_total")
    assert_equal(names[3], "o_id_right")
    assert_equal(names[4], "o_total_right")
    assert_equal(names[5], "reason")
    # Refunds are numbered 0, 2, .. 18, so ten of the forty orders match.
    var got = rows_of(m.batch)
    assert_equal(len(got), 10)
    expect_rows(
        got,
        expected_rows(
            orders_batch(0, 40), refund_batch(10), key_names("o_id"), key_names("o_id")
        ),
        "colliding names",
    )


# ---- key types ------------------------------------------------------------------


def test_an_int32_build_key_meets_an_int64_probe_key_by_value() raises:
    var got = _join(
        orders_batch(0, 60),
        customer_batch(25),
        key_names("o_custkey"),
        key_names("c_custkey"),
    )
    var want = expected_rows(
        orders_batch(0, 60),
        customer_batch(25),
        key_names("o_custkey"),
        key_names("c_custkey"),
    )
    assert_true(len(want) > 30)
    expect_rows(got, want, "int32 against int64")


def test_string_keys_join_with_null_matching_nothing() raises:
    var got = _join(
        tag_probe_batch(0, 40),
        tag_build_batch(12),
        key_names("p_tag"),
        key_names("b_tag"),
    )
    var want = expected_rows(
        tag_probe_batch(0, 40),
        tag_build_batch(12),
        key_names("p_tag"),
        key_names("b_tag"),
    )
    assert_true(len(want) > 0)
    expect_rows(got, want, "string keys")


def test_float_keys_match_nan_to_nan_and_negative_zero_to_zero() raises:
    var got = _join(
        float_probe_batch(24),
        float_build_batch(),
        key_names("f_key"),
        key_names("g_key"),
    )
    var want = expected_rows(
        float_probe_batch(24),
        float_build_batch(),
        key_names("f_key"),
        key_names("g_key"),
    )
    # Per six probe rows: -0.0 and 0.0 meet build row 0; NaN meets build row 1;
    # 1.5 meets rows 2 and 4; NULL and -1.5 meet nothing.
    assert_equal(len(want), 4 * (1 + 1 + 1 + 2))
    expect_rows(got, want, "float keys")


def test_a_composite_key_of_two_int64_columns_joins_on_both() raises:
    var got = _join(
        pair_probe_batch(30),
        pair_build_batch(20),
        key_names("k1", "k2"),
        key_names("j1", "j2"),
    )
    var want = expected_rows(
        pair_probe_batch(30),
        pair_build_batch(20),
        key_names("k1", "k2"),
        key_names("j1", "j2"),
    )
    assert_true(len(want) > 0)
    expect_rows(got, want, "composite key")


# ---- a worker's probe over several morsels ------------------------------------


def test_a_later_morsel_with_other_columns_gets_its_own_output_schema() raises:
    var spec = probe_op(1, key_names("k"), key_names("bk"))
    var shared = HashProbeShared(
        spec, _keys_batch("bk", "bv", [1, 1, 3, 4], [False, False, False, False])
    )
    var op = shared.make()
    var first = Morsel(
        _keys_batch("k", "v", [1, 2, 3], [False, False, False]), 0, 0
    )
    assert_true(op.execute(first).is_need_more_input())
    var names1 = column_names(first.batch)
    assert_equal(len(names1), 4)
    assert_equal(names1[0], "k")
    assert_equal(names1[3], "bv")
    # The second morsel has a column named like the build side's `bv`.
    var second = Morsel(
        _keys_batch("k", "v", [3, 4, 5], [False, False, False], "bv"), 1, 0
    )
    assert_true(op.execute(second).is_need_more_input())
    var names2 = column_names(second.batch)
    assert_equal(len(names2), 5)
    assert_equal(names2[1], "bv")
    assert_equal(names2[2], "v")
    assert_equal(names2[3], "bk")
    assert_equal(names2[4], "bv_right")
    expect_rows(
        rows_of(second.batch),
        expected_rows(
            _keys_batch("k", "v", [3, 4, 5], [False, False, False], "bv"),
            _keys_batch("bk", "bv", [1, 1, 3, 4], [False, False, False, False]),
            key_names("k"),
            key_names("bk"),
        ),
        "second schema",
    )
    # Back to the first schema.
    var third = Morsel(
        _keys_batch("k", "v", [1, 4], [False, False]), 2, 0
    )
    assert_true(op.execute(third).is_need_more_input())
    assert_equal(len(column_names(third.batch)), 4)
    assert_equal(third.num_rows(), 3)
    # The same column count under another payload name.
    var fourth = Morsel(_keys_batch("k", "w", [1], [False]), 3, 0)
    assert_true(op.execute(fourth).is_need_more_input())
    var names4 = column_names(fourth.batch)
    assert_equal(names4[1], "w")
    assert_equal(fourth.num_rows(), 2)
    # The same names with the payload as FLOAT64.
    var fifth = Morsel(_float_payload_batch(), 4, 0)
    assert_true(op.execute(fifth).is_need_more_input())
    assert_true(
        fifth.batch.schema.field_at_unchecked(1).arrow_type == ArrowType.FLOAT64
    )
    assert_equal(fifth.num_rows(), 2)


def test_an_empty_build_side_joins_nothing() raises:
    var spec = probe_op(1, key_names("o_custkey"), key_names("c_custkey"))
    var schema = customer_batch(1).schema.copy()
    var shared = HashProbeShared(spec, empty_batch_like_schema(schema))
    assert_equal(shared.build_rows(), 0)
    var op = shared.make()
    var m = Morsel(orders_batch(0, 30), 0, 0)
    assert_true(op.execute(m).is_filtered_empty())


def test_probes_of_one_shared_part_answer_for_their_own_morsels() raises:
    var spec = probe_op(1, key_names("o_custkey"), key_names("c_custkey"))
    var shared = HashProbeShared(spec, customer_batch(25))
    var one = shared.make()
    var two = shared.make()
    var got_one = _run(one, orders_batch(0, 30))
    var got_two = _run(two, orders_batch(30, 30))
    var again_one = _run(one, orders_batch(60, 20))
    expect_rows(
        got_one,
        expected_rows(
            orders_batch(0, 30), customer_batch(25), key_names("o_custkey"), key_names("c_custkey")
        ),
        "first probe",
    )
    expect_rows(
        got_two,
        expected_rows(
            orders_batch(30, 30), customer_batch(25), key_names("o_custkey"), key_names("c_custkey")
        ),
        "second probe",
    )
    expect_rows(
        again_one,
        expected_rows(
            orders_batch(60, 20), customer_batch(25), key_names("o_custkey"), key_names("c_custkey")
        ),
        "first probe again",
    )


def test_metrics_are_empty_before_a_morsel_and_count_after() raises:
    var spec = probe_op(1, key_names("o_custkey"), key_names("c_custkey"))
    var shared = HashProbeShared(spec, customer_batch(10))
    var op = shared.make()
    assert_equal(op.metrics_snapshot().count(), 0)
    var m = Morsel(orders_batch(0, 30), 0, 0)
    _ = op.execute(m)
    assert_true(op.metrics_snapshot().count() > 0)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
