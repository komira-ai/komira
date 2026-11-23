# =============================================================================
# test_lower_gcs_azure_scan: Parquet scans of GCS and Azure objects lowered
# to SOURCE_PARQUET
# =============================================================================
#
# A scan whose source names a GCS bucket or an Azure container
# (`FsDescriptorPod.cloud`) is cut as an S3 one is (test_lower_s3_scan): its
# spec carries the descriptor (`parquet_fs`) beside the object keys, so the
# engine reads the keys of that store and never a local file of the same
# name. Rows, for each of the two stores: one key with its projection and
# pushed filter, a total spec whose path is the key; several keys listed in
# order with the store; the render line names the store (`fs=gs://<bucket>`,
# `fs=az://<container>`) after `total=`.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true

from arrow.arrow_types import ArrowType
from arrow.schema import Field, Schema, SchemaBuilder
from host_profile.host_profile import reference_host_profile
from lowering.lower import lower
from lowering.lowered_plan import LoweredPlan, LoweringInputs
from lowering.render import render_lowered_plan
from physical_plan.physical_plan import SOURCE_PARQUET as SEG_SOURCE_PARQUET
from plan_expr.expr import Expr, BIN_GT
from plan_expr.fs_descriptor_pod import (
    FS_SCHEME_AZURE,
    FS_SCHEME_GCS,
    FsDescriptorPod,
)
from plan_expr.scalar_value import ScalarValue
from plan_ir.logical_plan import LogicalPlan
from scan_source.parquet_source import ParquetSource
from scan_source.source_variant import SourceVariant


def _schema() -> Schema:
    var sb = SchemaBuilder()
    sb.add_field(Field("k", ArrowType.INT64, False))
    sb.add_field(Field("v", ArrowType.INT64, False))
    return sb.build()


def _raw() -> FsDescriptorPod:
    return FsDescriptorPod.cloud(FS_SCHEME_GCS, String("raw"), 4)


def _box() -> FsDescriptorPod:
    return FsDescriptorPod.cloud(FS_SCHEME_AZURE, String("box"), 5)


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


def _one_key(desc: FsDescriptorPod) raises:
    var ps = ParquetSource(String("t/a.parquet"), _schema()).with_fs_descriptor(desc)
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
    assert_equal(Int(s.parquet_fs.scheme), Int(desc.scheme))
    assert_equal(s.parquet_fs.bucket, desc.bucket)
    assert_equal(s.parquet_fs.node_id, desc.node_id)
    assert_equal(s.parquet_projection.value()[0], "v")
    assert_equal(String(s.parquet_filter.value()), String(_k_gt(3)))
    assert_equal(len(seg.ops), 0)


def test_one_gcs_key_carries_its_bucket_projection_and_filter() raises:
    _one_key(_raw())


def test_one_azure_key_carries_its_container_projection_and_filter() raises:
    _one_key(_box())


def _several(desc: FsDescriptorPod, url: String) raises:
    var ps = ParquetSource.partitioned(
        _keys(), _schema(), List[Field](), List[List[String]]()
    ).with_fs_descriptor(desc)
    var lp = _lowered(LogicalPlan.scan_from_source(SourceVariant(ps^), _schema()))
    ref s = lp.segments[0].source_spec
    assert_equal(len(s.parquet_paths), 2)
    assert_equal(s.parquet_paths[0], "t/a.parquet")
    assert_equal(s.parquet_paths[1], "t/b.parquet")
    assert_equal(s.parquet_fs.url_prefix(), url)


def test_several_keys_are_listed_with_their_store() raises:
    _several(_raw(), "gs://raw")
    _several(_box(), "az://box")


def _render(desc: FsDescriptorPod) raises -> String:
    var ps = ParquetSource(String("t/a.parquet"), _schema()).with_fs_descriptor(desc)
    return render_lowered_plan(_lowered(LogicalPlan.scan_from_source(SourceVariant(ps^), _schema())))


def test_the_render_line_names_the_store() raises:
    var gcs = _render(_raw())
    assert_true("  source: SOURCE_PARQUET path=t/a.parquet total=True fs=gs://raw\n" in gcs, gcs)
    var azure = _render(_box())
    assert_true("  source: SOURCE_PARQUET path=t/a.parquet total=True fs=az://box\n" in azure, azure)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
