# A probe morsel carrying a selection mask: a masked-out row contributes no
# pair on any `JoinProbeOp` arm (no INNER or SEMI row, no unmatched LEFT or
# ANTI row). Two answers each arm must equal:
#   1. the same arm over the COMPACT batch (the kept rows gathered, no mask);
#   2. rows written out by hand.
# The mask keeps rows {0, 2, 4, 6, 7} of 8. The dropped rows 1, 3, 5 are rows
# that WOULD match (keys 5, 1, 2), so a leak adds INNER, SEMI and LEFT rows;
# kept rows 2 and 6 match nothing (keys 500, 700), so over-filtering loses
# ANTI and LEFT rows. Arms: PERFECT, RADIX, the resumable INNER, the
# whole-morsel INNER, SEMI, ANTI, LEFT; and no mask at all.

from std.memory import ArcPointer
from std.testing import TestSuite, assert_equal, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.boolean_array import BooleanArray
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch, RecordBatchBuilder
from komira_arrow.schema import Field, Schema, SchemaBuilder
from komira_morsel.morsel import Morsel
from komira_plan_ir.logical_plan import JOIN_INNER, JOIN_LEFT, JOIN_SEMI, JOIN_ANTI

from komira_op_join_build.join import HashJoinBuilder
from komira_op_join_build.join_perfect_hash import PerfectHashJoin
from komira_op_join_probe.join_probe_op import JoinProbeOp
from komira_op_join_probe.join_probe_op_state import (
    STRATEGY_STANDARD,
    STRATEGY_PERFECT,
    STRATEGY_RADIX,
    ColumnarProbeSharedState,
    build_shared_probe_state,
)
from komira_op_join_probe.radix_join import RadixPartitionedHashJoin


comptime _MISSING: Int64 = -1


def _kv(k: String, keys: List[Int64], v: String, vals: List[Int64]) raises -> RecordBatch:
    var sb = SchemaBuilder()
    sb.add_field(Field(k, ArrowType.INT64, False))
    sb.add_field(Field(v, ArrowType.INT64, False))
    var rb = RecordBatchBuilder()
    rb.add_column(Column.from_primitive[DType.int64](PrimitiveArray[DType.int64].from_list(keys)))
    rb.add_column(Column.from_primitive[DType.int64](PrimitiveArray[DType.int64].from_list(vals)))
    return rb.build(sb.build())


def _probe_keys() -> List[Int64]:
    return [3, 5, 500, 1, 4, 2, 700, 3]


def _keep() -> List[Bool]:
    return [True, False, True, False, True, False, True, True]


def _masked() raises -> RecordBatch:
    var b = _kv("pk", _probe_keys(), "pv", [100, 101, 102, 103, 104, 105, 106, 107])
    var m = BooleanArray.allocate(8)
    var keep = _keep()
    for i in range(8):
        m.set(i, keep[i])
    b.set_selection_mask(m^)
    return b^


def _compact() raises -> RecordBatch:
    var keys = _probe_keys()
    var keep = _keep()
    var k = List[Int64]()
    var v = List[Int64]()
    for i in range(8):
        if keep[i]:
            k.append(keys[i])
            v.append(Int64(100 + i))
    return _kv("pk", k, "pv", v)


def _build_keys() -> List[Int64]:
    var k = List[Int64]()
    for i in range(100):
        k.append(Int64(i + 1))
    return k^


def _op(join_type: UInt8, strategy: UInt8, slot: Bool) raises -> JoinProbeOp:
    """Build keys 1..100, bv = 10 * key."""
    var bk = _build_keys()
    var bv = List[Int64]()
    for i in range(100):
        bv.append(Int64((i + 1) * 10))
    var keys = PrimitiveArray[DType.int64].from_list(bk)
    var sb = SchemaBuilder()
    sb.add_field(Field("pk", ArrowType.INT64, False))
    sb.add_field(Field("pv", ArrowType.INT64, False))
    sb.add_field(Field("bk", ArrowType.INT64, True))
    sb.add_field(Field("bv", ArrowType.INT64, True))
    var perfect = Optional[ArcPointer[PerfectHashJoin]](None)
    var radix = Optional[ArcPointer[RadixPartitionedHashJoin]](None)
    if strategy == STRATEGY_PERFECT:
        var p = PerfectHashJoin.try_build(keys)
        assert_true(Bool(p), "fixture: 1..100 admits a perfect hash")
        perfect = ArcPointer[PerfectHashJoin](p.take())
    elif strategy == STRATEGY_RADIX:
        radix = ArcPointer[RadixPartitionedHashJoin](RadixPartitionedHashJoin.build(keys))
    var shared = Optional[ArcPointer[ColumnarProbeSharedState]](None)
    if slot:
        shared = build_shared_probe_state(1)
    return JoinProbeOp(
        ArcPointer[HashJoinBuilder](HashJoinBuilder.build(keys)),
        ArcPointer[RecordBatch](_kv("bk", bk, "bv", bv)),
        "pk", "bk",
        ArcPointer[Schema](sb.build()),
        join_type,
        shared=shared^,
        local_id=0 if slot else -1,
        strategy=strategy,
        perfect=perfect^,
        radix=radix^,
    )


def _run(join_type: UInt8, strategy: UInt8, slot: Bool, var probe: RecordBatch) raises -> RecordBatch:
    var op = _op(join_type, strategy, slot)
    var m = Morsel(probe^, 0, 0, 0)
    assert_true(op.execute(m).is_need_more_input(), "one call drains it")
    return m^.take_batch()


def _sorted(imm b: RecordBatch, name: String) raises -> List[Int64]:
    var a = b.column_at(b.schema.column_index(name)).as_primitive[DType.int64]()
    var out = List[Int64]()
    for i in range(a.length):
        out.append(_MISSING if a.is_null(i) else a.get(i))
    sort(out)
    return out^


def _assert(got: List[Int64], want: List[Int64], what: String) raises:
    assert_equal(len(got), len(want), what + ": rows")
    for i in range(len(want)):
        assert_equal(got[i], want[i], what + ": row " + String(i))


def _check(join_type: UInt8, strategy: UInt8, slot: Bool, pv: List[Int64], bv: List[Int64], what: String) raises:
    var masked = _run(join_type, strategy, slot, _masked())
    var compact = _run(join_type, strategy, slot, _compact())
    _assert(_sorted(masked, "pv"), pv, what + " pv")
    _assert(_sorted(compact, "pv"), pv, what + " pv, compact batch")
    if len(bv) > 0:
        _assert(_sorted(masked, "bv"), bv, what + " bv")
        _assert(_sorted(compact, "bv"), bv, what + " bv, compact batch")


def test_inner_on_every_arm() raises:
    """Kept matches: rows 0 (3), 4 (4), 7 (3)."""
    _check(JOIN_INNER, STRATEGY_PERFECT, False, [100, 104, 107], [30, 30, 40], "PERFECT")
    _check(JOIN_INNER, STRATEGY_RADIX, False, [100, 104, 107], [30, 30, 40], "RADIX")
    _check(JOIN_INNER, STRATEGY_STANDARD, True, [100, 104, 107], [30, 30, 40], "resumable")
    _check(JOIN_INNER, STRATEGY_STANDARD, False, [100, 104, 107], [30, 30, 40], "whole morsel")


def test_semi_anti_left() raises:
    _check(JOIN_SEMI, STRATEGY_STANDARD, False, [100, 104, 107], List[Int64](), "SEMI")
    _check(JOIN_ANTI, STRATEGY_STANDARD, False, [102, 106], List[Int64](), "ANTI")
    _check(
        JOIN_LEFT, STRATEGY_STANDARD, False, [100, 102, 104, 106, 107],
        [_MISSING, _MISSING, 30, 30, 40], "LEFT",
    )


def test_no_mask_keeps_every_row() raises:
    var out = _run(
        JOIN_INNER, STRATEGY_STANDARD, False,
        _kv("pk", _probe_keys(), "pv", [100, 101, 102, 103, 104, 105, 106, 107]),
    )
    _assert(_sorted(out, "pv"), [100, 101, 103, 104, 105, 107], "no mask")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
