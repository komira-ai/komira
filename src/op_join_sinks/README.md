# op_join_sinks

The per-worker operators a join pipeline constructs over the join probe
(`op_join_probe`). The package root re-exports nothing; import from the
modules.

- `op_join_sinks.join_probe_op_adapter`: `JoinProbeOpAdapter`, the
  single-key join probe a driver allocates per worker
  (`Slab[JoinProbeOpAdapter]`). It wraps one `JoinProbeOp`, takes its
  constructor arguments in the same order with the same defaults, and returns
  its results and metrics unchanged: the resumable INNER arm's
  HAVE_MORE_OUTPUT chunks, the deferred INNER output, the perfect-hash and
  radix INNER, LEFT, SEMI and ANTI.
- `op_join_sinks.multi_probe_op_adapter`: the probe cascades, which run
  a chain of joins against finished builds over one morsel, each probe's
  output the next probe's input. `MultiProbeOpAdapter` chains single-key
  `JoinProbeOp`s and `MultiKeyProbeCascadeAdapter` chains composite-key
  `MultiKeyJoinProbeOp`s. With one probe, either adapter is that probe. With
  more, every probe must finish its morsel in one call: a probe that returns
  HAVE_MORE_OUTPUT is an error, not a cut-short answer. A probe whose output
  is empty ends the chain for that morsel. An empty cascade is refused.
- `op_join_sinks.finalized_hash_index`: `FinalizedHashIndex`, a finished
  single-INT64-key table (`op_join_build`'s `HashJoinBuilder`), the
  build batch it indexes, and a matched flag per build row that any worker may
  set (`mark_matched`, a relaxed atomic store). `collect_marked_indices` lists
  the rows whose flag is set or clear, ascending, each once.
- `op_join_sinks.mark_semi_anti`: `MarkSemiAntiProbeOp`, the marking
  pass of a SEMI or ANTI join that builds its LEFT side and streams its RIGHT
  side. Each RIGHT morsel marks every LEFT row whose key it holds; the morsel
  is emptied (NEED_MORE_INPUT), and after the workers finish the caller reads
  the SEMI rows (flag set) or ANTI rows (flag clear) from the index, in LEFT
  row order. A NULL key on either side matches nothing, and a RIGHT row the
  morsel's selection mask excludes marks nothing. Keys are INT64; a key column
  of another type is refused, as the single-key probe refuses it.

## Tests

The tests are welded into the library target, so building
`//src/op_join_sinks:op_join_sinks` runs them:

- `test_join_probe_op_adapter`: every join type with a NULL probe key against
  the rows written in the test and against a bare `JoinProbeOp`; SEMI count
  only; the resumable INNER arm's two chunks; the metrics.
- `test_multi_probe_op_adapter`: one probe, a two-probe cascade row by row, an
  empty first probe, the refusal of a probe that returns HAVE_MORE_OUTPUT
  inside a cascade, the empty cascade, and a composite cascade with NULL keys
  and FLOAT64 keys (NaN equals NaN, -0.0 equals +0.0).
- `test_mark_semi_anti`: the SEMI and ANTI answers over every chain-entry
  layout of the table with the bloom on and off, two workers sharing one
  index, the selection mask, a nested-loop cross-check over 2,000 by 9,000
  rows, empty sides, the index's checks, and the refusal of a FLOAT64 key.

## Examples

`JoinProbeOpAdapter` takes the constructor arguments of the `JoinProbeOp` it wraps: the finished build table, the build batch, the probe and build key names, the output schema and the join type. `execute` replaces the morsel's batch with the join result and answers NEED_MORE_INPUT. Here an INNER join keeps the probe rows whose key the build side holds, in probe order, with the build row's columns appended:

```mojo module
from std.memory import ArcPointer
from std.testing import assert_equal, assert_true

from arrow.arrow_types import ArrowType
from arrow.column import Column
from arrow.primitive_array import PrimitiveArray
from arrow.record_batch import RecordBatch, RecordBatchBuilder
from arrow.schema import Field, Schema, SchemaBuilder
from morsel.morsel import Morsel
from plan_ir.logical_plan import JOIN_INNER

from op_join_build.join import HashJoinBuilder

from op_join_sinks.join_probe_op_adapter import JoinProbeOpAdapter


def _kv(k: String, keys: List[Int64], v: String, vals: List[Int64]) raises -> RecordBatch:
    var sb = SchemaBuilder()
    sb.add_field(Field(k, ArrowType.INT64, True))
    sb.add_field(Field(v, ArrowType.INT64, False))
    var rb = RecordBatchBuilder()
    rb.add_column(Column.from_primitive[DType.int64](PrimitiveArray[DType.int64].from_list(keys)))
    rb.add_column(Column.from_primitive[DType.int64](PrimitiveArray[DType.int64].from_list(vals)))
    return rb.build(sb.build())


def _output_schema() raises -> Schema:
    var sb = SchemaBuilder()
    sb.add_field(Field("pk", ArrowType.INT64, True))
    sb.add_field(Field("pv", ArrowType.INT64, False))
    sb.add_field(Field("bk", ArrowType.INT64, True))
    sb.add_field(Field("bv", ArrowType.INT64, True))
    return sb.build()


def _column(b: RecordBatch, name: String) raises -> List[Int64]:
    var a = b.column_at(b.schema.column_index(name)).as_primitive[DType.int64]()
    var out = List[Int64]()
    for i in range(a.length):
        out.append(a.get(i))
    return out^


def main() raises:
    var build_keys: List[Int64] = [10, 20, 30]
    var adapter = JoinProbeOpAdapter(
        ArcPointer[HashJoinBuilder](
            HashJoinBuilder.build(PrimitiveArray[DType.int64].from_list(build_keys))
        ),
        ArcPointer[RecordBatch](_kv("bk", build_keys, "bv", [100, 200, 300])),
        "pk",
        "bk",
        ArcPointer[Schema](_output_schema()),
        JOIN_INNER,
    )
    var m = Morsel(_kv("pk", [30, 99, 20], "pv", [1000, 1001, 1002]), 0, 0, 0)
    assert_true(adapter.execute(m).is_need_more_input())
    assert_equal(m.batch.num_rows(), 2)
    var pv = _column(m.batch, "pv")
    var bv = _column(m.batch, "bv")
    assert_equal(pv[0], Int64(1000))
    assert_equal(bv[0], Int64(300))
    assert_equal(pv[1], Int64(1002))
    assert_equal(bv[1], Int64(200))
```

`MarkSemiAntiProbeOp` is the marking pass of a SEMI or ANTI join that builds its LEFT side. The LEFT keys go into a `FinalizedHashIndex`, each RIGHT morsel marks the LEFT rows whose key it holds, and the SEMI rows (flag set) and ANTI rows (flag clear) come back in LEFT row order:

```mojo module
from std.memory import ArcPointer
from std.testing import assert_equal, assert_true

from arrow.arrow_types import ArrowType
from arrow.column import Column
from arrow.primitive_array import PrimitiveArray
from arrow.record_batch import RecordBatch, RecordBatchBuilder
from arrow.schema import Field, SchemaBuilder
from morsel.morsel import Morsel

from op_join_build.join import HashJoinBuilder

from op_join_sinks.finalized_hash_index import FinalizedHashIndex
from op_join_sinks.mark_semi_anti import MarkSemiAntiProbeOp


def _keys(name: String, keys: List[Int64]) raises -> RecordBatch:
    var sb = SchemaBuilder()
    sb.add_field(Field(name, ArrowType.INT64, True))
    var rb = RecordBatchBuilder()
    rb.add_column(Column.from_primitive[DType.int64](PrimitiveArray[DType.int64].from_list(keys)))
    return rb.build(sb.build())


def main() raises:
    var left = _keys("lk", [5, 7, 5, 0])
    var keys = left.column_at(0).as_primitive[DType.int64]()
    var builder = HashJoinBuilder.build(keys)
    var index = ArcPointer[FinalizedHashIndex](FinalizedHashIndex(builder^, left^))
    assert_equal(index[].num_rows(), 4)

    var op = MarkSemiAntiProbeOp(ArcPointer[FinalizedHashIndex](copy=index), "rk")
    var m = Morsel(_keys("rk", [5, 0, 100]), 0, 0, 0)
    assert_true(op.execute(m).is_need_more_input())
    assert_equal(m.batch.num_rows(), 0)

    var semi = index[].collect_marked_indices(True)
    assert_equal(len(semi), 3)
    assert_equal(semi[0], 0)
    assert_equal(semi[1], 2)
    assert_equal(semi[2], 3)
    var anti = index[].collect_marked_indices(False)
    assert_equal(len(anti), 1)
    assert_equal(anti[0], 1)
    assert_true(index[].is_matched(0))
```
