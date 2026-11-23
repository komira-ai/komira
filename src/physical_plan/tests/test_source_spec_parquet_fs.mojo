# =============================================================================
# test_source_spec_parquet_fs -- the store a SOURCE_PARQUET arm reads
# =============================================================================
#
# `SourceSpecPod.parquet_fs` names the store the files are on. Rows: an empty
# spec and each Parquet mint given no store name the local file system, so a
# spec minted before the field reads the local disk as before; each Parquet
# mint keeps the bucket it is given (scheme, bucket and node id), beside its
# paths, which are then object keys.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true

from arrow.schema import Field
from physical_plan.physical_plan import SourceSpecPod
from plan_expr.fs_descriptor_pod import FS_SCHEME_S3, FsDescriptorPod


def _keys() -> List[String]:
    var out = List[String]()
    out.append("t/a.parquet")
    out.append("t/b.parquet")
    return out^


def test_a_spec_given_no_store_reads_the_local_file_system() raises:
    assert_true(SourceSpecPod().parquet_fs.is_local())
    assert_true(SourceSpecPod.parquet("a.parquet", None, None, True).parquet_fs.is_local())
    assert_true(
        SourceSpecPod.parquet_files(_keys(), List[Field](), List[List[String]](), None, None)
        .parquet_fs.is_local()
    )


def test_the_one_file_mint_keeps_its_bucket() raises:
    var s = SourceSpecPod.parquet(
        "t/a.parquet", None, None, True, FsDescriptorPod.cloud(FS_SCHEME_S3, "lake", 4)
    )
    assert_equal(s.parquet_path, "t/a.parquet")
    assert_equal(Int(s.parquet_fs.scheme), Int(FS_SCHEME_S3))
    assert_equal(s.parquet_fs.bucket, "lake")
    assert_equal(s.parquet_fs.node_id, 4)


def test_the_files_mint_keeps_its_bucket() raises:
    var s = SourceSpecPod.parquet_files(
        _keys(),
        List[Field](),
        List[List[String]](),
        None,
        None,
        FsDescriptorPod.cloud(FS_SCHEME_S3, "lake", 2),
    )
    assert_equal(len(s.parquet_paths), 2)
    assert_equal(s.parquet_fs.url_prefix(), "s3://lake")
    assert_equal(s.parquet_fs.node_id, 2)
    assert_true(s.parquet_spec_is_total)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
