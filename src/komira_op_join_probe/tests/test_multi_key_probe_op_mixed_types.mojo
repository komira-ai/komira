# `MultiKeyJoinProbeOp` over key pairs that mix an integer key with a FLOAT64
# key, which compare as FLOAT64 (DuckDB casts the integer side to DOUBLE):
#   * an INT64 probe key against a FLOAT64 build key, as one pair of two
#     keys, matches 1 with 1.0 (the morsel's integer key is cast);
#   * a FLOAT64 probe key against an INT64 build key raises when the index
#     holds that key as an integer, and matches 1.0 with 1 when the index was
#     built with it as FLOAT64 and the operator is told so;
#   * a STRING probe key against an INT64 build key raises.

from std.memory import ArcPointer
from std.testing import TestSuite, assert_equal, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch, RecordBatchBuilder
from komira_arrow.schema import Field, Schema, SchemaBuilder
from komira_arrow.string_array import StringArray
from komira_buffer.heap_region import HeapRegion
from komira_morsel.morsel import Morsel, split_record_batch
from komira_collections.slab import Slab
from komira_plan_ir.logical_plan import JOIN_INNER

from komira_op_join_probe.join_key_extract import (
    extract_join_key_columns_serial,
    join_key_pairs_as_float64,
)
from komira_op_join_probe.join_multi_key_builder import MultiKeyHashJoinBuilder
from komira_op_join_probe.multi_key_probe_op import MultiKeyJoinProbeOp


def _i64(vals: List[Int64]) -> Column[HeapRegion]:
    return Column.from_primitive[DType.int64](
        PrimitiveArray[DType.int64].from_list(vals)
    )


def _f64(vals: List[Float64]) -> Column[HeapRegion]:
    return Column.from_primitive[DType.float64](
        PrimitiveArray[DType.float64].from_list(vals)
    )


def _batch(
    n1: String, t1: ArrowType, var c1: Column[HeapRegion],
    n2: String, t2: ArrowType, var c2: Column[HeapRegion],
    id: String,
) raises -> RecordBatch:
    """Key columns `n1`, `n2`, then `id` (0, 1, ...)."""
    var ids = List[Int64]()
    for i in range(c1.length()):
        ids.append(Int64(i))
    var sb = SchemaBuilder()
    sb.add_field(Field(n1, t1, True))
    sb.add_field(Field(n2, t2, True))
    sb.add_field(Field(id, ArrowType.INT64, False))
    var rb = RecordBatchBuilder()
    rb.add_column(c1^)
    rb.add_column(c2^)
    rb.add_column(_i64(ids))
    return rb.build(sb.build())


def _out_schema(imm probe: RecordBatch, imm build: RecordBatch) raises -> Schema:
    var sb = SchemaBuilder()
    for c in range(probe.num_columns()):
        sb.add_field(Field("p_" + probe.schema.field_name(c), probe.schema.field_arrow_type(c), True))
    for c in range(build.num_columns()):
        sb.add_field(Field("b_" + build.schema.field_name(c), build.schema.field_arrow_type(c), True))
    return sb.build()


def _join(
    var probe: RecordBatch,
    var build: RecordBatch,
    build_as_float64: List[Bool],
) raises -> List[Int64]:
    """The operator over `probe` in one-row morsels, keys (k, k2) against
    (bk, bk2), the index built with `build_as_float64`; each output row as
    `(probe id + 1) * 100 + (build id + 1)`, sorted."""
    var pkeys: List[String] = ["k", "k2"]
    var bkeys: List[String] = ["bk", "bk2"]
    var schema = _out_schema(probe, build)
    var builder = MultiKeyHashJoinBuilder.build(
        extract_join_key_columns_serial(build, bkeys, build_as_float64)
    )
    var op = MultiKeyJoinProbeOp(
        ArcPointer[MultiKeyHashJoinBuilder](builder^),
        ArcPointer[RecordBatch](build^),
        pkeys.copy(),
        bkeys.copy(),
        ArcPointer[Schema](schema^),
        JOIN_INNER,
        build_as_float64=build_as_float64,
    )
    var morsels = split_record_batch(probe^, 1)
    var slab = Slab[Morsel]()
    morsels.drain_morsels_into(slab)
    var out = List[Int64]()
    for i in range(len(slab)):
        _ = op.execute(slab[i])
        ref b = slab[i].batch
        if b.num_rows() == 0:
            continue
        var p = b.column_at(b.schema.column_index("p_pid")).as_primitive[DType.int64]()
        var q = b.column_at(b.schema.column_index("b_bid")).as_primitive[DType.int64]()
        for r in range(p.length):
            out.append((p.get(r) + 1) * 100 + (q.get(r) + 1))
    sort(out)
    return out^


def _int_probe() raises -> RecordBatch:
    return _batch(
        "k", ArrowType.INT64, _i64([1, 2]),
        "k2", ArrowType.INT64, _i64([5, 6]), "pid",
    )


def _float_probe() raises -> RecordBatch:
    return _batch(
        "k", ArrowType.FLOAT64, _f64([1.0, 2.5]),
        "k2", ArrowType.INT64, _i64([5, 6]), "pid",
    )


def _int_build() raises -> RecordBatch:
    return _batch(
        "bk", ArrowType.INT64, _i64([1, 2]),
        "bk2", ArrowType.INT64, _i64([5, 7]), "bid",
    )


def _float_build() raises -> RecordBatch:
    return _batch(
        "bk", ArrowType.FLOAT64, _f64([1.0, 2.0]),
        "bk2", ArrowType.INT64, _i64([5, 7]), "bid",
    )


def test_int64_probe_key_against_float64_build_key() raises:
    """Probe (1, 5), (2, 6) against build (1.0, 5), (2.0, 7): one row."""
    var got = _join(_int_probe(), _float_build(), List[Bool]())
    assert_equal(len(got), 1, "rows")
    assert_equal(got[0], 101, "probe 0 with build 0")


def test_float64_probe_key_against_an_integer_index_raises() raises:
    var raised = False
    try:
        _ = _join(_float_probe(), _int_build(), List[Bool]())
    except e:
        raised = "build_as_float64" in String(e)
    assert_true(raised, "an index holding the INT64 key as an integer")


def test_float64_probe_key_against_a_float64_index() raises:
    """The index built as `join_key_pairs_as_float64` says: probe (1.0, 5)
    matches build (1, 5); probe (2.5, 6) matches nothing."""
    var as_f = join_key_pairs_as_float64(
        _float_probe(), ["k", "k2"], _int_build(), ["bk", "bk2"]
    )
    assert_true(as_f[0] and not as_f[1], "pairs")
    var got = _join(_float_probe(), _int_build(), as_f)
    assert_equal(len(got), 1, "rows")
    assert_equal(got[0], 101, "probe 0 with build 0")


def test_string_probe_key_against_int64_build_key_raises() raises:
    var probe = _batch(
        "k", ArrowType.STRING, Column.from_string(StringArray.from_strings(["1", "2"])),
        "k2", ArrowType.INT64, _i64([5, 6]), "pid",
    )
    var raised = False
    try:
        _ = _join(probe^, _int_build(), List[Bool]())
    except e:
        raised = "explicit cast" in String(e)
    assert_true(raised, "STRING against INT64 must raise")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
