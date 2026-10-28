# =============================================================================
# test_agg_cd_group_topk_bounded_drain -- the bounded drain for
# `TOPN(k) -> grouped COUNT(DISTINCT)` emits exactly what the full drain plus
# the caller's own top-N emits, and every decline emits every group
# =============================================================================
#
# The oracle is the composition the bounded arm claims to reproduce: the
# DECLINED drain (every group) followed by `_execute_topn_sink` under the
# hint's comparator. The assertion is byte identity of the string key column
# and value identity of the aggregate column, row by row (the order is part of
# the answer under `ORDER BY ... LIMIT`).
#
# What each test catches:
#   * equivalence (descending, ascending, a tie at the cut): a bounded arm that
#     picks different survivors or returns them in a different order (an
#     appended tie-break key would do the latter at the tied cut);
#   * `test_bounded_arm_actually_fires`: an arm that silently declines would
#     pass every equivalence; the row count (k, not every group) tells them
#     apart;
#   * the declines (an ORDER BY on a group key, an unknown column, k <= 0, a
#     malformed comparator, the ratio boundary, no hint): a hint the arm does
#     not serve must emit every group, never raise and never answer wrongly.
#
# Group g sees exactly g + 1 distinct values, so the ORDER BY is a total order
# and mis-attributed rows cannot agree by accident; the tie test uses a second
# fixture whose counts collide across the cut. The fixture has 70,000 rows, so
# K > 1 workers run (asserted as a precondition).
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch
from komira_arrow.schema import (
    Field, RecordBatchBuilder, SchemaBuilder,
)
from komira_arrow.string_array import StringArray
from komira_buffer.heap_region import HeapRegion
from komira_plan_expr.agg_expr import count_distinct
from komira_plan_expr.col_expr import col
from komira_plan_ir.logical_plan import AggExprArray, ExprArray
from komira_physical_plan.physical_plan import AggSinkData, TopNSinkData

from komira_async.cancellation.token import CancellationToken
from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import BACKEND_MOCK
from komira_async.runtime.runtime import PLACEMENT_FIXED, PerCoreAsyncRuntime

from komira_op_agg_distinct.agg_cd_group_topk import (
    CDP_TOPK_MIN_RATIO,
    CdGroupTopKHint,
)
from komira_op_agg_distinct.agg_count_distinct_parallel import (
    _execute_count_distinct_agg_parallel,
    _should_use_parallel_count_distinct,
)
from komira_op_sort.sort_topn_sink import _execute_topn_sink


comptime _ROWS: Int = 70_000
comptime _WORKERS: Int = 4
comptime _GROUPS: Int = 200
comptime _K: Int = 10


def _key_at(g: Int) raises -> String:
    """Group `g`'s key. All-different lengths, an empty value at g == 0, and a
    multi-byte UTF-8 value every seventh group whose `byte_length` exceeds its
    character count — so an emit that pushed CHARACTERS rather than BYTES
    would diverge on the offsets, not merely on the decoded text."""
    if g == 0:
        return String("")
    if g % 7 == 3:
        return String("aé-") + String(g)
    var s = String("g")
    for _ in range(g % 11):
        s += String("x")
    return s + String(g)


def _batch(distinct_of_group: List[Int]) raises -> RecordBatch:
    """`_ROWS` rows over `_GROUPS` string keys; group `g` sees exactly
    `distinct_of_group[g]` distinct INT64 values."""
    var keys = List[String]()
    var vals = List[Int64]()
    for i in range(_ROWS):
        var g = i % _GROUPS
        keys.append(_key_at(g))
        vals.append(Int64((i // _GROUPS) % distinct_of_group[g]))
    var kcol = Column.from_string(StringArray.from_strings(keys))
    var vcol = Column.from_primitive[DType.int64](
        PrimitiveArray[DType.int64].from_list(vals)
    )
    var sb = SchemaBuilder()
    sb.add_field(Field("k", ArrowType.STRING, False))
    sb.add_field(Field("v", ArrowType.INT64, False))
    var b = RecordBatchBuilder.with_capacity(2)
    b.add_column(kcol^)
    b.add_column(vcol^)
    return b.build(sb.build())


def _total_order_counts() -> List[Int]:
    """Group `g` gets `g + 1` distinct values — a TOTAL order on the ORDER BY
    column, so the top-k cut is unambiguous."""
    var out = List[Int](capacity=_GROUPS)
    for g in range(_GROUPS):
        out.append(g + 1)
    return out^


def _tied_at_the_cut_counts() -> List[Int]:
    """Every group's distinct count is `(g % 5) + 1`, so FORTY groups share
    each value and the k == 10 cut falls in the middle of a forty-way tie. The
    surviving SET is then decided entirely by the tie-break policy."""
    var out = List[Int](capacity=_GROUPS)
    for g in range(_GROUPS):
        out.append((g % 5) + 1)
    return out^


def _sink_data() raises -> AggSinkData:
    var group_by = ExprArray()
    group_by.append(col("k").copy_expr())
    var aggs = AggExprArray()
    aggs.append(count_distinct(col("v")))
    var osb = SchemaBuilder()
    osb.add_field(Field("k", ArrowType.STRING, False))
    osb.add_field(Field("n", ArrowType.INT64, False))
    return AggSinkData(group_by^, aggs^, osb.build())


def _noop_sink_factory() -> NoopSink:
    return NoopSink(_placeholder=UInt8(0))


def _hint(imm name: String, desc: Bool, k: Int) -> CdGroupTopKHint:
    var cols = List[String]()
    cols.append(String(name))
    var d = List[Bool]()
    d.append(desc)
    return CdGroupTopKHint(cols^, d^, k)


def _run_cd(
    counts: List[Int], var hint: Optional[CdGroupTopKHint]
) raises -> RecordBatch:
    """Drive the PARALLEL count-distinct driver directly, routing predicate
    asserted first as a PRECONDITION (see this file's header)."""
    if not _should_use_parallel_count_distinct(_ROWS, _WORKERS):
        raise Error(
            "PRECONDITION FAILED: n="
            + String(_ROWS)
            + " no longer routes to the PARALLEL count-distinct driver; this"
            " file would not be testing the driver"
        )
    var batch = _batch(counts)
    var sink = _sink_data()
    var rt = PerCoreAsyncRuntime[NoopSink](placement=PLACEMENT_FIXED)
    rt.attach_workers(_WORKERS, _noop_sink_factory, BACKEND_MOCK)
    rt.start()
    ref disp = rt.dispatcher()
    var ct = CancellationToken.new()
    return _execute_count_distinct_agg_parallel(
        disp, ct.clone(), batch, sink, 1, 1, _ROWS, hint^
    )


def _oracle(counts: List[Int], desc: Bool, k: Int) raises -> RecordBatch:
    """THE ORACLE: the DECLINED drain (every group) followed by the caller's
    own `TOPN(k)` over the caller's own comparator. This composition is what
    the bounded arm claims to reproduce, so it is what the bounded arm is
    compared against — never a hand-written expected answer."""
    var full = _run_cd(counts, None)
    var keys = List[String]()
    keys.append(String("n"))
    var d = List[Bool]()
    d.append(desc)
    return _execute_topn_sink(full^, TopNSinkData(keys^, d^, k))


def _key_bytes(imm rb: RecordBatch) raises -> List[UInt8]:
    """Every offset byte and every data byte of column 0. Comparing DECODED
    strings would not be a byte-identity claim — two different (offsets, data)
    pairs can decode to the same values."""
    var sa = rb.column_at(0).as_string()
    var out = List[UInt8]()
    for i in range(sa.length + 1):
        var o = Int(sa.offsets.get_typed[Int32](i))
        out.append(UInt8(o & 0xFF))
        out.append(UInt8((o >> 8) & 0xFF))
        out.append(UInt8((o >> 16) & 0xFF))
        out.append(UInt8((o >> 24) & 0xFF))
    for i in range(sa.data_length):
        out.append(sa.data.get_typed[UInt8](i))
    return out^


def _agg_vals(imm rb: RecordBatch) raises -> List[Int]:
    var pa = rb.column_at(1).as_primitive[DType.int64]()
    var out = List[Int]()
    for i in range(rb.num_rows()):
        out.append(Int(pa.get(i)))
    return out^


def _assert_same_answer(
    imm got: RecordBatch, imm want: RecordBatch, imm what: String
) raises:
    assert_equal(got.num_rows(), want.num_rows(), what + ": row count")
    assert_equal(
        got.schema.num_columns(), want.schema.num_columns(), what + ": columns"
    )
    for c in range(want.schema.num_columns()):
        assert_equal(
            got.schema.field_name(c), want.schema.field_name(c), what + ": name"
        )
        assert_true(
            got.schema.field_arrow_type(c) == want.schema.field_arrow_type(c),
            what + ": arrow type of column " + String(c),
        )
    var gb = _key_bytes(got)
    var wb = _key_bytes(want)
    assert_equal(len(gb), len(wb), what + ": key BYTE count")
    for i in range(len(wb)):
        assert_equal(Int(gb[i]), Int(wb[i]), what + ": key byte " + String(i))
    var gv = _agg_vals(got)
    var wv = _agg_vals(want)
    for i in range(len(wv)):
        assert_equal(gv[i], wv[i], what + ": agg value " + String(i))


# =============================================================================
# the equivalence, and the route witness that keeps it non-vacuous
# =============================================================================


def test_bounded_emits_what_the_full_drain_plus_topn_emits() raises:
    var counts = _total_order_counts()
    var got = _run_cd(counts, Optional(_hint("n", True, _K)))
    var want = _oracle(counts, True, _K)
    _assert_same_answer(got, want, "DESC top-k")


def test_bounded_arm_actually_fires() raises:
    """The non-vacuousness assertion. The mechanism is value-invariant, so
    every equivalence above passes an arm that silently declined. The row
    COUNT is the one observable that separates served from declined."""
    var counts = _total_order_counts()
    var served = _run_cd(counts, Optional(_hint("n", True, _K)))
    var declined = _run_cd(counts, None)
    assert_equal(served.num_rows(), _K, "served must emit exactly k rows")
    assert_equal(
        declined.num_rows(), _GROUPS, "declined must emit every group"
    )


def test_ascending_order_is_honoured() raises:
    """The hint's direction is the CALLER'S, not an assumption. An arm that
    hard-coded DESC would pass every test above and fail this one."""
    var counts = _total_order_counts()
    var got = _run_cd(counts, Optional(_hint("n", False, _K)))
    var want = _oracle(counts, False, _K)
    _assert_same_answer(got, want, "ASC top-k")
    assert_equal(got.num_rows(), _K, "ASC must still be bounded")


def test_a_tie_at_the_cut_agrees_with_the_full_drain() raises:
    """FORTY groups share each ORDER BY value, so the k == 10 cut falls inside
    a tie and the surviving SET is decided purely by the tie-break policy.

    This is the assertion that catches an appended tie-break key. With a trailing
    `__cdp_topk_gidx` ASC key appended to the comparator — the spelling
    `agg_group_topk`'s radix twin ships — this goes RED at `key byte 8`. An
    explicit sorted-key probe run at the same time proved the divergence is a
    PERMUTATION and not a set difference (`PROBE: sets are EQUAL`), which is
    why the twin's own SET-only assertion stays green on its fixture while
    this one does not. See `agg_cd_group_topk`'s header for the mechanism.

    ⇒ A COST CHANGE MAY NOT REORDER TIED ROWS EITHER. The corpus value gate is
    a commutative multiset fold and the row-order gate only asserts
    MONOTONICITY of the order key, so a tie permutation would pass both — this
    fixture is the only thing in the tree that can see it."""
    var counts = _tied_at_the_cut_counts()
    var got = _run_cd(counts, Optional(_hint("n", True, _K)))
    var want = _oracle(counts, True, _K)
    _assert_same_answer(got, want, "tied-at-the-cut top-k")
    assert_equal(got.num_rows(), _K, "tie case must still be bounded")


# =============================================================================
# every DECLINE emits every group. A hint this module does not
#      understand degrades to today's COST, never to a wrong answer.
# =============================================================================


def test_declines_when_an_order_key_is_a_group_key() raises:
    """The selection runs over a pre-pass that deliberately does NOT carry the
    group keys — that omission IS the mechanism — so a comparator naming one
    cannot be served. A TOPN over a grouped count of a string key takes this
    arm."""
    var counts = _total_order_counts()
    var got = _run_cd(counts, Optional(_hint("k", True, _K)))
    assert_equal(got.num_rows(), _GROUPS, "a key comparator must decline")


def test_declines_on_an_unknown_order_column() raises:
    """An unknown name means the hint is not about this aggregate. It must
    DECLINE, never raise — a `Schema.column_index` here would convert an
    un-updated pass into a failed query."""
    var counts = _total_order_counts()
    var got = _run_cd(counts, Optional(_hint("no_such_column", True, _K)))
    assert_equal(got.num_rows(), _GROUPS, "an unknown comparator declines")


def test_declines_when_k_is_not_positive() raises:
    var counts = _total_order_counts()
    var zero = _run_cd(counts, Optional(_hint("n", True, 0)))
    assert_equal(zero.num_rows(), _GROUPS, "k == 0 declines")
    var neg = _run_cd(counts, Optional(_hint("n", True, -3)))
    assert_equal(neg.num_rows(), _GROUPS, "k < 0 declines")


def test_declines_when_the_comparator_is_malformed() raises:
    var counts = _total_order_counts()
    var cols = List[String]()
    cols.append(String("n"))
    var d = List[Bool]()   # length mismatch: one column, no direction
    var got = _run_cd(counts, Optional(CdGroupTopKHint(cols^, d^, _K)))
    assert_equal(got.num_rows(), _GROUPS, "a malformed hint declines")


def test_the_min_ratio_boundary_is_where_we_think() raises:
    """`n_groups <= k * CDP_TOPK_MIN_RATIO` declines, `>` admits — pinned on
    BOTH sides of the exact boundary, so a change to the constant turns this
    RED instead of silently widening or narrowing the arm's reach."""
    var counts = _total_order_counts()
    var at = _GROUPS // CDP_TOPK_MIN_RATIO          # 200 <= 25*8 -> decline
    var below = at - 1                               # 200 >  24*8 -> admit
    assert_equal(
        _run_cd(counts, Optional(_hint("n", True, at))).num_rows(),
        _GROUPS,
        "k at the ratio boundary must decline",
    )
    assert_equal(
        _run_cd(counts, Optional(_hint("n", True, below))).num_rows(),
        below,
        "k one below the boundary must be served",
    )


def test_no_hint_is_the_incumbent_drain() raises:
    var counts = _total_order_counts()
    assert_equal(
        _run_cd(counts, None).num_rows(),
        _GROUPS,
        "no hint must emit every group",
    )


def test_declines_when_nulls_first_disagrees_in_length() raises:
    """A NULL placement list that does not match the ORDER BY columns is a
    malformed comparator: decline."""
    var counts = _total_order_counts()
    var cols = List[String]()
    cols.append(String("n"))
    var d = List[Bool]()
    d.append(True)
    var nf = List[Bool]()
    nf.append(True)
    nf.append(False)
    var got = _run_cd(counts, Optional(CdGroupTopKHint(cols^, d^, _K, nf^)))
    assert_equal(got.num_rows(), _GROUPS, "a malformed NULL placement declines")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
