# The DEFERRED INNER arm of `JoinProbeOp`, through the operator. The route is
# answer-preserving, so every case first asserts WHICH route ran (the
# narrow-marshal and payload-substitution counters) and then the record's
# contents, compared index by index with literals or with the other route:
#   * fused and two-pass (the setting off) drains record the same pairs, in
#     the same order, at 4-byte width;
#   * a selection mask keeps a drain off the fused route (and the same morsel
#     without a mask takes it: the refusal is not unreachability);
#   * a fan-out morsel whose pairs outgrow the sink's first reservation and
#     span kernel chunks records the same pairs on both routes;
#   * a morsel the deferral rule declines is staged, with the same rows on
#     both routes (the fused one widens back, counted);
#   * with an inlined payload and payload substitution, a deferred record drops
#     its build index; a declined one is staged with the right rows;
#   * the morsel leaves the operator empty on every path.

from std.memory import ArcPointer
from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_arrow.arrow_types import ArrowType
from komira_arrow.boolean_array import BooleanArray
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch, RecordBatchBuilder
from komira_arrow.schema import Field, Schema, SchemaBuilder
from komira_join_assembly.join_payload_inline import (
    join_pay_subst_configure,
    join_pay_subst_elided_count,
    join_pay_subst_reset_config,
    reset_join_pay_subst_counters,
)
from komira_morsel.morsel import Morsel

from komira_op_join_build.join import HashJoinBuilder
from komira_op_join_probe.join_deferred import (
    JoinDeferredState,
    build_join_deferred_state,
)
from komira_op_join_probe.join_probe_narrow import (
    join_narrow_marshal_configure,
    join_narrow_marshal_fused_drains,
    join_narrow_marshal_legacy_drains,
    join_narrow_marshal_reset_config,
    join_narrow_marshal_widened_pairs,
    reset_join_narrow_marshal_counters,
)
from komira_op_join_probe.join_probe_op import JoinProbeOp
from komira_op_join_probe.join_probe_op_state import (
    ColumnarProbeSharedState,
    build_shared_probe_state,
)


def _kv(k: String, keys: List[Int64], v: String, vals: List[Int64]) raises -> RecordBatch:
    var sb = SchemaBuilder()
    sb.add_field(Field(k, ArrowType.INT64, False))
    sb.add_field(Field(v, ArrowType.INT64, False))
    var rb = RecordBatchBuilder()
    rb.add_column(Column.from_primitive[DType.int64](PrimitiveArray[DType.int64].from_list(keys)))
    rb.add_column(Column.from_primitive[DType.int64](PrimitiveArray[DType.int64].from_list(vals)))
    return rb.build(sb.build())


def _schema() raises -> Schema:
    var sb = SchemaBuilder()
    sb.add_field(Field("pk", ArrowType.INT64, False))
    sb.add_field(Field("pv", ArrowType.INT64, False))
    sb.add_field(Field("bk", ArrowType.INT64, False))
    sb.add_field(Field("bv", ArrowType.INT64, False))
    return sb.build()


struct _Run(Movable):
    """One operator with a deferred state, and what it recorded."""

    var op: JoinProbeOp
    var state: ArcPointer[JoinDeferredState]

    def __init__(
        out self, bk: List[Int64], bv: List[Int64], admit: Bool, pay: Bool = False
    ) raises:
        """`admit`: every priceable morsel defers (force); else every one is
        declined (a zero output width). `pay`: the table inlines `bv`."""
        var keys = PrimitiveArray[DType.int64].from_list(bk)
        var builder = HashJoinBuilder.build(
            keys, pay_values=bv.copy(), pay_build_col=1
        ) if pay else HashJoinBuilder.build(keys)
        var state = build_join_deferred_state(
            1, out_row_width=32 if admit else 0, out_num_cols=4, force_defer=admit
        )
        var op = JoinProbeOp(
            ArcPointer[HashJoinBuilder](builder^),
            ArcPointer[RecordBatch](_kv("bk", bk, "bv", bv)),
            "pk", "bk",
            ArcPointer[Schema](_schema()),
            shared=Optional[ArcPointer[ColumnarProbeSharedState]](build_shared_probe_state(1)),
            local_id=0,
            deferred=Optional[ArcPointer[JoinDeferredState]](
                ArcPointer[JoinDeferredState](copy=state)
            ),
        )
        self.op = op^
        self.state = state^

    def probe(mut self, var batch: RecordBatch) raises:
        var m = Morsel(batch^, 0, 3, 9)
        assert_true(self.op.execute(m).is_need_more_input(), "one call")
        assert_equal(m.batch.num_rows(), 0, "the morsel leaves empty")


def _record_pairs(imm run: _Run, i: Int) raises -> List[Int]:
    """Record `i`'s pairs as `probe * 1000 + build` (deferred, 4-byte)."""
    ref rec = run.state[].buckets.get_mut_interior(0).chunks[i]
    assert_true(rec.deferred, "a deferred record")
    assert_true(rec.idx32, "4-byte indices")
    assert_equal(rec.partition_id, 3)
    assert_equal(rec.origin_hint, 9)
    var out = List[Int]()
    for j in range(rec.num_rows):
        out.append(Int(rec.probe_idx32[j]) * 1000 + Int(rec.build_idx32[j]))
    return out^


def _records(imm run: _Run) -> Int:
    return len(run.state[].buckets.get_mut_interior(0).chunks)


def _assert(got: List[Int], want: List[Int], what: String) raises:
    assert_equal(len(got), len(want), what + ": pairs")
    for i in range(len(want)):
        assert_equal(got[i], want[i], what + ": pair " + String(i))


def _base_probe() raises -> RecordBatch:
    """pk 30, 99, 20, 30, 50, 10, 77, 40, 30, 1."""
    return _kv("pk", [30, 99, 20, 30, 50, 10, 77, 40, 30, 1], "pv", [0, 1, 2, 3, 4, 5, 6, 7, 8, 9])


def _base_run(admit: Bool) raises -> _Run:
    return _Run([10, 20, 30, 40, 50], [100, 200, 300, 400, 500], admit)


def _drain(fuse: Bool, var probe: RecordBatch, var run: _Run) raises -> _Run:
    join_narrow_marshal_configure(fuse)
    reset_join_narrow_marshal_counters()
    run.probe(probe^)
    join_narrow_marshal_reset_config()
    return run^


def test_fused_and_two_pass_record_the_same_pairs() raises:
    """Matches in probe order: (0,2) (2,1) (3,2) (4,4) (5,0) (7,3) (8,2)."""
    var want: List[Int] = [2, 2001, 3002, 4004, 5000, 7003, 8002]
    var fused = _drain(True, _base_probe(), _base_run(True))
    assert_equal(join_narrow_marshal_fused_drains(), 1, "the fused route ran")
    assert_equal(join_narrow_marshal_legacy_drains(), 0, "only it")
    _assert(_record_pairs(fused, 0), want, "fused")
    var walk = _drain(False, _base_probe(), _base_run(True))
    assert_equal(join_narrow_marshal_legacy_drains(), 1, "the two-pass route ran")
    assert_equal(join_narrow_marshal_fused_drains(), 0, "only it")
    _assert(_record_pairs(walk, 0), want, "two-pass")


def test_a_selection_mask_keeps_the_fused_route_off() raises:
    """Keep rows 0..4: the masked walk drops rows 5..9's pairs."""
    var masked = _base_probe()
    var m = BooleanArray.allocate(10)
    for i in range(10):
        m.set(i, i < 5)
    masked.set_selection_mask(m^)
    var run = _drain(True, masked^, _base_run(True))
    assert_equal(join_narrow_marshal_fused_drains(), 0, "the mask refused the fused route")
    assert_equal(join_narrow_marshal_legacy_drains(), 1, "the masked walk ran")
    _assert(_record_pairs(run, 0), [2, 2001, 3002, 4004], "masked")
    _ = _drain(True, _base_probe(), _base_run(True))
    assert_equal(join_narrow_marshal_fused_drains(), 1, "without the mask it fuses")


def _fan_probe() raises -> RecordBatch:
    """600 probe rows of keys 0..39 (cycling)."""
    var k = List[Int64]()
    var v = List[Int64]()
    for i in range(600):
        k.append(Int64(i % 40))
        v.append(Int64(i))
    return _kv("pk", k, "pv", v)


def _fan_run() raises -> _Run:
    """Each key 0..39 on 200 build rows: 120,000 matches, more than the
    sink's first reservation and more than one kernel chunk."""
    var k = List[Int64]()
    var v = List[Int64]()
    for i in range(8000):
        k.append(Int64(i % 40))
        v.append(Int64(i))
    return _Run(k, v, True)


def test_fan_out_beyond_a_chunk_records_the_same_pairs() raises:
    var fused = _drain(True, _fan_probe(), _fan_run())
    assert_equal(join_narrow_marshal_fused_drains(), 1, "fused")
    var walk = _drain(False, _fan_probe(), _fan_run())
    assert_equal(join_narrow_marshal_legacy_drains(), 1, "two-pass")
    var a = _record_pairs(fused, 0)
    assert_equal(len(a), 120_000, "every pair")
    _assert(a, _record_pairs(walk, 0), "fused vs two-pass")


def _staged_rows(imm run: _Run) raises -> List[Int]:
    """The staged record's rows as `pv * 1000 + bv`, sorted."""
    ref rec = run.state[].buckets.get_mut_interior(0).chunks[0]
    assert_false(rec.deferred, "a staged record")
    var pv = rec.staged.column_at(1).as_primitive[DType.int64]()
    var bv = rec.staged.column_at(3).as_primitive[DType.int64]()
    var out = List[Int]()
    for i in range(rec.staged.num_rows()):
        out.append(Int(pv.get(i)) * 1000 + Int(bv.get(i)))
    sort(out)
    return out^


def test_a_declined_morsel_is_staged_the_same_on_both_routes() raises:
    var want: List[Int] = [300, 2200, 3300, 4500, 5100, 7400, 8300]
    var fused = _drain(True, _base_probe(), _base_run(False))
    assert_equal(join_narrow_marshal_widened_pairs(), 7, "widened back")
    _assert(_staged_rows(fused), want, "fused, staged")
    var walk = _drain(False, _base_probe(), _base_run(False))
    _assert(_staged_rows(walk), want, "two-pass, staged")


def test_payload_substitution_drops_the_build_index() raises:
    """The table inlines bv; the build key aliases the probe key; so a
    deferred record keeps the probe index and the payload only."""
    join_pay_subst_configure(True)
    reset_join_pay_subst_counters()
    var run = _Run([10, 20, 30, 40, 50], [100, 200, 300, 400, 500], True, pay=True)
    run.probe(_base_probe())
    assert_equal(join_pay_subst_elided_count(), 1, "the build index was elided")
    ref rec = run.state[].buckets.get_mut_interior(0).chunks[0]
    assert_true(rec.build_idx_elided, "the record dropped its build index")
    assert_equal(len(rec.build_pay), 7, "a payload per pair")
    var pay_sum = 0
    for j in range(len(rec.build_pay)):
        pay_sum += Int(rec.build_pay[j])
    assert_equal(pay_sum, 300 + 200 + 300 + 500 + 100 + 400 + 300, "payloads")
    _ = run^  # `rec` is an untracked reference into it
    join_pay_subst_reset_config()


def test_a_declined_substituted_morsel_is_staged_with_the_right_rows() raises:
    join_pay_subst_configure(True)
    var run = _Run([10, 20, 30, 40, 50], [100, 200, 300, 400, 500], False, pay=True)
    run.probe(_base_probe())
    _assert(_staged_rows(run), [300, 2200, 3300, 4500, 5100, 7400, 8300], "staged")
    join_pay_subst_reset_config()


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
