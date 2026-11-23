# A Parquet scan's store is part of the plan's identity: its render (which
# `structural_hash` and `plan_cse`'s subtree identity are built from) names a
# remote store, so the same object key in two buckets, or a local file and an
# object of one name, are never one subtree.
#
# Rows: a scan of bucket `lake` renders `, fs=s3://lake` after its type; the
# same key in bucket `other` renders differently and hashes differently; a
# local scan of that path renders no store, and differs from both.
from std.testing import assert_false, assert_true

from arrow.arrow_types import ArrowType
from arrow.schema import Field, Schema, SchemaBuilder
from plan_expr.fs_descriptor_pod import FS_SCHEME_S3, FsDescriptorPod
from plan_ir.logical_plan import LogicalPlan
from scan_source.parquet_source import ParquetSource
from scan_source.source_variant import SourceVariant


def _schema() -> Schema:
    var sb = SchemaBuilder()
    sb.add_field(Field("id", ArrowType.INT64, False))
    return sb.build()


def _scan(bucket: String) raises -> LogicalPlan:
    var ps = ParquetSource(String("t/a.parquet"), _schema())
    if bucket.byte_length() > 0:
        ps = ps.with_fs_descriptor(FsDescriptorPod.cloud(FS_SCHEME_S3, bucket, 0))
    return LogicalPlan.scan_from_source(SourceVariant(ps^), _schema())


def test_a_remote_scan_renders_its_store() raises:
    var text = String(_scan("lake"))
    assert_true(", fs=s3://lake" in text, text)


def test_one_key_in_two_buckets_is_two_plans() raises:
    var lake = _scan("lake")
    var other = _scan("other")
    assert_true(String(lake) != String(other))
    assert_true(lake.structural_hash() != other.structural_hash())


def test_a_local_scan_renders_no_store() raises:
    var local = _scan("")
    var text = String(local)
    assert_false(", fs=" in text, text)
    assert_true(local.structural_hash() != _scan("lake").structural_hash())


def main() raises:
    test_a_remote_scan_renders_its_store()
    test_one_key_in_two_buckets_is_two_plans()
    test_a_local_scan_renders_no_store()
    print("OK")
