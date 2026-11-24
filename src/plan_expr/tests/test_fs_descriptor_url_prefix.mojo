# `FsDescriptorPod.url_prefix`: the store a descriptor names, spelled as the
# URL prefix messages and rendered plans show.
#
# Rows: each scheme code gives its own prefix with the bucket (the local
# descriptor gives `file://`, with no bucket); a code that is no scheme is
# named by its number, never shown as a known store.
from std.testing import assert_equal

from plan_expr.fs_descriptor_pod import (
    FS_SCHEME_AZURE,
    FS_SCHEME_GCS,
    FS_SCHEME_S3,
    FsDescriptorPod,
)


def test_each_scheme_spells_its_prefix() raises:
    assert_equal(FsDescriptorPod.local().url_prefix(), "file://")
    assert_equal(FsDescriptorPod.cloud(FS_SCHEME_S3, "lake", 0).url_prefix(), "s3://lake")
    assert_equal(FsDescriptorPod.cloud(FS_SCHEME_GCS, "raw", 1).url_prefix(), "gs://raw")
    assert_equal(FsDescriptorPod.cloud(FS_SCHEME_AZURE, "box", 2).url_prefix(), "az://box")


def test_an_unknown_code_is_named_by_its_number() raises:
    assert_equal(FsDescriptorPod.cloud(UInt8(9), "b", 0).url_prefix(), "scheme 9://b")


def main() raises:
    test_each_scheme_spells_its_prefix()
    test_an_unknown_code_is_named_by_its_number()
    print("OK")
