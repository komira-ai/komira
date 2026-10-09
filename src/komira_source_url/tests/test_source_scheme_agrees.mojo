# The scheme code komira_source_url maps each prefix to is the SCHEME the
# file system serving it advertises, so a plan built from the mapping names
# the file system that will read it. The codes are written down more than
# once: komira_plan_expr's FS_SCHEME_* (which S3Fs, GcsFs and AzureFs take
# their SCHEME from) and komira_fs's FileSystem default SCHEME, a literal 0
# that LocalFs keeps. This test holds every copy to the mapping, so a drift
# in either reds the build.
#
# Rows: file:// and a bare path give LocalFs's SCHEME; s3:// and s3a:// give
# S3Fs's, over the production connector and over a scripted one alike (the
# connector does not change the scheme); gs:// and gcs:// give GcsFs's;
# az://, abfs://, abfss:// and an Azure Blob https:// host give AzureFs's,
# over both connectors; the four codes are pairwise distinct, and the plan's
# constants are 0, 1, 2 and 3 (the wire codes).
from std.testing import assert_equal, assert_true

from komira_async.ops.waker_sink import NoopSink
from komira_aws_core import ProcessCredsSource, StaticCredsSource, SystemAwsClock
from komira_azure_blob import AzureFs
from komira_fs.local_fs import LocalFs
from komira_http_client import KernelSchemeConnector
from komira_http_core.transport.scripted import ScriptedConnector
from komira_objectstore_gcs import FakeGcsStorageBackend, GcsFs
from komira_objectstore_s3 import S3Fs
from komira_plan_expr.fs_descriptor_pod import (
    FS_SCHEME_AZURE,
    FS_SCHEME_FILE,
    FS_SCHEME_GCS,
    FS_SCHEME_S3,
)
from komira_source_url import source_scheme_for_url


def test_local() raises:
    assert_equal(source_scheme_for_url("file:///data/a.parquet"), LocalFs[NoopSink].SCHEME)
    assert_equal(source_scheme_for_url("data/a.parquet"), LocalFs[NoopSink].SCHEME)


def test_s3() raises:
    comptime prod = S3Fs[KernelSchemeConnector, ProcessCredsSource, SystemAwsClock].SCHEME
    comptime scripted = S3Fs[ScriptedConnector, StaticCredsSource, SystemAwsClock].SCHEME
    assert_equal(source_scheme_for_url("s3://lake/a.parquet"), prod)
    assert_equal(source_scheme_for_url("s3a://lake/a.parquet"), prod)
    assert_equal(scripted, prod)


def test_gcs() raises:
    comptime gcs = GcsFs[FakeGcsStorageBackend].SCHEME
    assert_equal(source_scheme_for_url("gs://lake/a.parquet"), gcs)
    assert_equal(source_scheme_for_url("gcs://lake/a.parquet"), gcs)


def test_azure() raises:
    comptime prod = AzureFs[KernelSchemeConnector].SCHEME
    assert_equal(source_scheme_for_url("az://lake/a.parquet"), prod)
    assert_equal(source_scheme_for_url("abfs://lake/a.parquet"), prod)
    assert_equal(source_scheme_for_url("abfss://lake@myacct.dfs.core.windows.net/a"), prod)
    assert_equal(
        source_scheme_for_url("https://myacct.blob.core.windows.net/lake/a.parquet"), prod
    )
    assert_equal(AzureFs[ScriptedConnector].SCHEME, prod)


def test_the_codes_are_distinct_wire_codes() raises:
    assert_equal(Int(FS_SCHEME_FILE), 0)
    assert_equal(Int(FS_SCHEME_S3), 1)
    assert_equal(Int(FS_SCHEME_GCS), 2)
    assert_equal(Int(FS_SCHEME_AZURE), 3)
    var codes: List[UInt8] = [
        LocalFs[NoopSink].SCHEME,
        S3Fs[KernelSchemeConnector, ProcessCredsSource, SystemAwsClock].SCHEME,
        GcsFs[FakeGcsStorageBackend].SCHEME,
        AzureFs[KernelSchemeConnector].SCHEME,
    ]
    for i in range(len(codes)):
        for j in range(i + 1, len(codes)):
            assert_true(codes[i] != codes[j], "two file systems share a scheme code")


def main() raises:
    test_local()
    test_s3()
    test_gcs()
    test_azure()
    test_the_codes_are_distinct_wire_codes()
    print("OK")
