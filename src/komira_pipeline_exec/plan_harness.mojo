# =============================================================================
# plan_harness -- hand-built plans over the real members
# =============================================================================
#
# What a test, or a measurement before the binder exists, needs to run a plan
# it wrote by hand through `run_plan` and `RealBuilder`:
#
#   * segment descriptors for the three sources with an operator chain and a
#     collect sink (`parquet_segment`, `batch_segment`, `output_segment`);
#   * the operators of the chain (`op_filter`, `op_project`, `op_limit`);
#   * a sample batch and readers for what comes out of a plan.
#
# The sample batch has three columns:
#   a  INT64, no NULL, row r holds r
#   b  INT64, NULL where r % 5 == 2, else r * 10
#   s  STRING, no NULL, "s" followed by r % 4
# for the rows start .. start + rows - 1.

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.schema import (
    Field,
    RecordBatch,
    RecordBatchBuilder,
    SchemaBuilder,
)
from komira_arrow.string_array import StringArray
from komira_collections.slab import Slab
from komira_physical_plan.physical_plan import (
    EDGE_E3_PUBLISH_WAIT,
    KEY_DTYPE_NONE,
    MorselOp,
    ORDER_NONE,
    SegmentDescPod,
    SINK_COLLECT,
    SINK_ORIENT_COLUMNAR,
    SOURCE_BATCH,
    SOURCE_PARQUET,
    SOURCE_SINK_OUTPUT,
    SourceSpecPod,
)
from komira_plan_expr.expr import Expr


def _segment(
    seg_id: Int,
    source_kind: UInt8,
    var spec: SourceSpecPod,
    var ops: Slab[MorselOp],
    morsel_rows: Int,
    var deps: List[Int],
    var tags: List[UInt8],
) -> SegmentDescPod:
    return SegmentDescPod(
        seg_id,
        source_kind,
        spec^,
        ops^,
        SINK_COLLECT,
        KEY_DTYPE_NONE,
        SINK_ORIENT_COLUMNAR,
        -1,
        seg_id,
        deps^,
        tags^,
        order_key_kind=ORDER_NONE,
        morsel_rows=morsel_rows,
    )


def parquet_segment(
    seg_id: Int,
    var path: String,
    var projection: Optional[List[String]] = None,
    var filter: Optional[Expr] = None,
    var ops: Slab[MorselOp] = Slab[MorselOp](),
    morsel_rows: Int = 0,
) -> SegmentDescPod:
    """A segment that scans the Parquet file or glob `path` and collects. The
    spec is total: path, projection and filter are the whole scan."""
    return _segment(
        seg_id,
        SOURCE_PARQUET,
        SourceSpecPod.parquet(path^, projection^, filter^, True),
        ops^,
        morsel_rows,
        List[Int](),
        List[UInt8](),
    )


def batch_segment(
    seg_id: Int,
    handle: Int,
    var ops: Slab[MorselOp] = Slab[MorselOp](),
    morsel_rows: Int = 0,
) -> SegmentDescPod:
    """A segment that reads resident batch `handle` and collects."""
    return _segment(
        seg_id,
        SOURCE_BATCH,
        SourceSpecPod.batch(handle),
        ops^,
        morsel_rows,
        List[Int](),
        List[UInt8](),
    )


def output_segment(
    seg_id: Int,
    producer: Int,
    var ops: Slab[MorselOp] = Slab[MorselOp](),
    morsel_rows: Int = 0,
) -> SegmentDescPod:
    """A segment that reads the output of segment `producer` (an edge that
    waits for it) and collects."""
    var deps = List[Int]()
    deps.append(producer)
    var tags = List[UInt8]()
    tags.append(EDGE_E3_PUBLISH_WAIT)
    return _segment(
        seg_id,
        SOURCE_SINK_OUTPUT,
        SourceSpecPod.from_sink_output(producer),
        ops^,
        morsel_rows,
        deps^,
        tags^,
    )


def chain(var a: MorselOp) -> Slab[MorselOp]:
    """An operator chain of one."""
    var ops = Slab[MorselOp]()
    ops.append(a^)
    return ops^


def chain(var a: MorselOp, var b: MorselOp) -> Slab[MorselOp]:
    """An operator chain of two, `a` first."""
    var ops = Slab[MorselOp]()
    ops.append(a^)
    ops.append(b^)
    return ops^


def chain(var a: MorselOp, var b: MorselOp, var c: MorselOp) -> Slab[MorselOp]:
    """An operator chain of three, `a` first."""
    var ops = Slab[MorselOp]()
    ops.append(a^)
    ops.append(b^)
    ops.append(c^)
    return ops^


def project_columns(names: List[String]) -> MorselOp:
    """An OP_PROJECT of bare column references to `names`, in that order: it
    reorders, drops and repeats columns, and evaluates nothing."""
    var exprs = Slab[Expr]()
    for i in range(len(names)):
        exprs.append(Expr.col_ref(names[i]))
    return MorselOp.project(exprs^, names.copy())


def b_is_null(r: Int) -> Bool:
    """Whether the sample batch holds NULL in column b at row r."""
    return r % 5 == 2


def sample_batch(start: Int, rows: Int) raises -> RecordBatch:
    """Rows `start .. start + rows - 1` of the sample table."""
    var a = PrimitiveArray[DType.int64].allocate(rows)
    var b = PrimitiveArray[DType.int64].allocate_nullable(rows)
    var s = List[String]()
    for i in range(rows):
        var r = start + i
        a.set(i, Int64(r))
        b.set(i, Int64(r * 10))
        if b_is_null(r):
            b._set_null(i)
        s.append(String("s") + String(r % 4))
    var sb = SchemaBuilder()
    var builder = RecordBatchBuilder()
    sb.add_field(Field("a", ArrowType.INT64, False))
    builder.add_column(Column.from_primitive[DType.int64](a^))
    sb.add_field(Field("b", ArrowType.INT64, True))
    builder.add_column(Column.from_primitive[DType.int64](b^))
    sb.add_field(Field("s", ArrowType.STRING, False))
    builder.add_column(Column.from_string(StringArray.from_strings(s)))
    return builder.build(sb.build())


def int64_column(ref batch: RecordBatch, col: Int) raises -> List[Int]:
    """The values of INT64 column `col`; a NULL reads as the value stored
    under it, so pair this with `null_column`."""
    var out = List[Int]()
    var values = batch.column_at(col).as_primitive[DType.int64]()
    for i in range(batch.num_rows()):
        out.append(Int(values.get(i)))
    return out^


def null_column(ref batch: RecordBatch, col: Int) -> List[Bool]:
    """Whether each row of column `col` is NULL."""
    var out = List[Bool]()
    for i in range(batch.num_rows()):
        out.append(batch.column_at(col).is_null_at(i))
    return out^


def string_column(ref batch: RecordBatch, col: Int) raises -> List[String]:
    """The values of STRING column `col`."""
    var out = List[String]()
    var values = batch.column_at(col).as_string()
    for i in range(batch.num_rows()):
        out.append(values.get(i))
    return out^


def column_names(ref batch: RecordBatch) raises -> List[String]:
    """The field names of `batch`, in order."""
    var out = List[String]()
    for i in range(batch.num_columns()):
        out.append(batch.schema.field_name(i))
    return out^
