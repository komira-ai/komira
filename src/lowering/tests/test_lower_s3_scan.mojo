# =============================================================================
# test_lower_s3_scan: a Parquet scan of S3 objects lowered to SOURCE_PARQUET
# =============================================================================
#
# A scan whose source names an S3 bucket (`FsDescriptorPod.cloud`) is cut
# like a local one, and its spec carries the descriptor (`parquet_fs`) beside
# the object keys, so the engine reads the keys of that bucket and never a
# local file of the same name. Rows: one key with its projection and pushed
# filter, a total spec whose path is the key; several keys listed in order;
# Hive partitioned keys with their partition constants and the filter and
# projection as operators; the render line names the store after `total=`,
# and a local scan's render line names none (so every local golden stays as
# it was).
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from arrow.arrow_types import ArrowType
from arrow.schema import Field, Schema, SchemaBuilder
from host_profile.host_profile import reference_host_profile
from lowering.lower import lower
from lowering.lowered_plan import LoweredPlan, LoweringInputs
from lowering.render import render_lowered_plan
from physical_plan.physical_plan import (
    OP_FILTER,
    OP_PROJECT,
    SOURCE_PARQUET as SEG_SOURCE_PARQUET,
)
from plan_expr.expr import Expr, BIN_GT
from plan_expr.fs_descriptor_pod import FS_SCHEME_S3, FsDescriptorPod
from plan_expr.scalar_value import ScalarValue
from plan_ir.logical_plan import LogicalPlan
from scan_source.parquet_source import ParquetSource
from scan_source.source_variant import SourceVariant


def _schema() -> Schema:
    var sb = SchemaBuilder()
    sb.add_field(Field("k", ArrowType.INT64, False))
    sb.add_field(Field("v", ArrowType.INT64, False))
    return sb.build()


def _lake() -> FsDescriptorPod:
    return FsDescriptorPod.cloud(FS_SCHEME_S3, String("lake"), 7)


def _k_gt(v: Int64) -> Expr:
    return Expr.binary(BIN_GT, Expr.col_ref("k"), Expr.literal(ScalarValue.from_int64(v)))


def _proj_v() -> List[String]:
    var out = List[String]()
    out.append("v")
    return out^


def _lowered(plan: LogicalPlan) raises -> LoweredPlan:
    var inputs = LoweringInputs()
    inputs.add_scan()
    return lower(plan, reference_host_profile("test-build"), inputs)


def _keys() -> List[String]:
    var out = List[String]()
    out.append("t/a.parquet")
    out.append("t/b.parquet")
    return out^


def test_one_key_carries_its_bucket_projection_and_filter() raises:
    var ps = ParquetSource(String("t/a.parquet"), _schema()).with_fs_descriptor(_lake())
    var plan = LogicalPlan.scan_from_source(
        SourceVariant(ps^), _schema(), Optional(_proj_v()), Optional(_k_gt(3))
    )
    var lp = _lowered(plan)
    assert_equal(len(lp.segments), 1)
    ref seg = lp.segments[0]
    assert_equal(seg.source_kind, SEG_SOURCE_PARQUET)
    ref s = seg.source_spec
    assert_equal(s.parquet_path, "t/a.parquet")
    assert_true(s.parquet_spec_is_total)
    assert_equal(Int(s.parquet_fs.scheme), Int(FS_SCHEME_S3))
    assert_equal(s.parquet_fs.bucket, "lake")
    assert_equal(s.parquet_fs.node_id, 7)
    assert_equal(s.parquet_projection.value()[0], "v")
    assert_equal(String(s.parquet_filter.value()), String(_k_gt(3)))
    assert_equal(len(seg.ops), 0)


def test_several_keys_are_listed_with_their_bucket() raises:
    var ps = ParquetSource.partitioned(
        _keys(), _schema(), List[Field](), List[List[String]]()
    ).with_fs_descriptor(_lake())
    var lp = _lowered(LogicalPlan.scan_from_source(SourceVariant(ps^), _schema()))
    ref s = lp.segments[0].source_spec
    assert_equal(len(s.parquet_paths), 2)
    assert_equal(s.parquet_paths[1], "t/b.parquet")
    assert_equal(s.parquet_fs.url_prefix(), "s3://lake")


def _one(value: String) -> List[String]:
    var out = List[String]()
    out.append(value)
    return out^


def test_hive_keys_keep_their_constants_and_bucket() raises:
    var keys = List[String]()
    keys.append("dt=a/x.parquet")
    keys.append("dt=b/y.parquet")
    var cols = List[Field]()
    cols.append(Field("dt", ArrowType.STRING, False))
    var values = List[List[String]]()
    values.append(_one("a"))
    values.append(_one("b"))
    var full = SchemaBuilder()
    full.add_field(Field("k", ArrowType.INT64, False))
    full.add_field(Field("v", ArrowType.INT64, False))
    full.add_field(Field("dt", ArrowType.STRING, False))
    var ps = ParquetSource.partitioned(keys^, _schema(), cols^, values^).with_fs_descriptor(_lake())
    var plan = LogicalPlan.scan_from_source(
        SourceVariant(ps^), full.build(), Optional(_proj_v()), Optional(_k_gt(1))
    )
    var lp = _lowered(plan)
    ref seg = lp.segments[0]
    ref s = seg.source_spec
    assert_equal(s.parquet_fs.bucket, "lake")
    assert_equal(len(s.parquet_partition_values), 2)
    assert_equal(s.parquet_partition_values[1][0], "b")
    assert_false(Bool(s.parquet_filter))
    assert_equal(len(seg.ops), 2)
    assert_equal(seg.ops[0].tag, OP_FILTER)
    assert_equal(seg.ops[1].tag, OP_PROJECT)


def test_the_render_line_names_the_store_of_a_remote_scan_only() raises:
    var remote = ParquetSource(String("t/a.parquet"), _schema()).with_fs_descriptor(_lake())
    var text = render_lowered_plan(_lowered(LogicalPlan.scan_from_source(SourceVariant(remote^), _schema())))
    assert_true("  source: SOURCE_PARQUET path=t/a.parquet total=True fs=s3://lake\n" in text, text)
    var local = ParquetSource(String("t/a.parquet"), _schema())
    var local_text = render_lowered_plan(_lowered(LogicalPlan.scan_from_source(SourceVariant(local^), _schema())))
    assert_true("  source: SOURCE_PARQUET path=t/a.parquet total=True\n" in local_text, local_text)
    assert_false(" fs=" in local_text, local_text)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
