# =============================================================================
# komira_table_store/tests/test_lost_slot_is_anchored.mojo
#   The table store's three lost-slot classifiers may not read a PATH as a
#   412 (komira-ai/komira#1275).
# =============================================================================
#
# `table_store._is_lost_slot_412`, `TableStoreHeadReader.classify_read_error`
# and `TableStoreExactSlotAppender.classify_append_error` matched a bare `412`
# anywhere in a store error. A LocalFs rename failure names the root, the key
# and a 16-hex temp suffix, so an I/O failure under a root holding `412` was
# read as a lost slot (re-read and retry) or a conflict, never as the I/O
# failure it is. The fix matches `status=412`, the HTTP projection the cloud
# conformers append, instead of the bare digits.
#
# What each case catches:
#   * test_an_io_error_whose_path_spells_412_is_not_a_lost_slot: FAILS BEFORE
#     THE FIX on its first `assert_false(_is_lost_slot_412(...))`.
#   * test_a_cloud_412_is_still_a_lost_slot: a GCS/Azure/S3 412 carries no
#     lowercase `precondition` and no `If-None-Match`; deleting the
#     `status=412` needle turns it red, in all three classifiers.
#
# HERMETIC: pure classification over in-memory stores.
# =============================================================================

from std.testing import assert_equal, assert_false, assert_true

from komira_objectstore.cas_manifest import CasManifestStore, RetryPolicy
from komira_objectstore.coalescing_window import (
    APPEND_ERR,
    APPEND_LOST_SLOT,
    READ_ERR_CONFLICT,
    READ_ERR_FATAL,
)
from komira_objectstore.shared_in_memory_conditional_store import (
    SharedInMemoryConditionalStore,
)
from komira_objectstore.shared_in_memory_slow_cas_store import (
    SharedInMemorySlowCasStore,
)

from komira_table_store.table_store import _is_lost_slot_412
from komira_table_store.group_commit import (
    TableStoreExactSlotAppender,
    TableStoreHeadReader,
)


comptime _Store = SharedInMemorySlowCasStore


def _wal(backing: SharedInMemoryConditionalStore, prefix: String) -> CasManifestStore[_Store]:
    var slow = SharedInMemorySlowCasStore(inner=backing.clone(), slow_ticks=0)
    return CasManifestStore[_Store](
        store=slow^, prefix=prefix, retry=RetryPolicy.fast_test()
    )


def _io_errors() -> List[String]:
    """I/O failures whose only `412` is inside a path."""
    var out = List[String]()
    # LocalFsConditionalStore._write_atomic's message, a root holding 412.
    out.append(
        String(
            "LocalFsConditionalStore: atomic rename failed"
            " ('/srv/ts-412/t/manifest/_HEAD.tmp.9f3a0c7d1e2b5a68' ->"
            " '/srv/ts-412/t/manifest/_HEAD', rc=-1)"
        )
    )
    # The same, with the random temp suffix spelling 412.
    out.append(
        String(
            "LocalFsConditionalStore: atomic rename failed"
            " ('/srv/ts/t/manifest/_HEAD.tmp.00c4120e9a7b3d5f' ->"
            " '/srv/ts/t/manifest/_HEAD', rc=-1)"
        )
    )
    # A 403 about manifest chunk 412, in the cloud conformers' shape.
    out.append(
        String(
            "StoreError[PERMISSION_DENIED] PutObject s3://b/t/manifest/"
            "00000000000000000412.chunk status=403"
        )
    )
    return out^


def _cloud_412s() -> List[String]:
    var out = List[String]()
    out.append(
        String(
            "StoreError[PRECONDITION] WriteObject gs://b/t/manifest/"
            "00000000000000000007.chunk status=412 grpc_code=9"
        )
    )
    out.append(String("StoreError[PRECONDITION] PUT az://c/t/_HEAD status=412"))
    out.append(String("StoreError[PRECONDITION] PutObject s3://b/t/_HEAD status=412"))
    return out^


def test_an_io_error_whose_path_spells_412_is_not_a_lost_slot() raises:
    print("[ts-412] an I/O error whose path spells 412 is not a lost slot")
    var backing = SharedInMemoryConditionalStore()
    var reader = TableStoreHeadReader[_Store](_wal(backing, "ts412/r"))
    var app = TableStoreExactSlotAppender[_Store](_wal(backing, "ts412/a"))
    var errs = _io_errors()
    for i in range(len(errs)):
        var m = errs[i]
        assert_true(m.find("412") >= 0, msg="premise: carries 412: " + m)
        assert_false(_is_lost_slot_412(m), msg="_is_lost_slot_412: " + m)
        assert_equal(
            Int(reader.classify_read_error(m)), Int(READ_ERR_FATAL), m
        )
        assert_equal(
            Int(app.classify_append_error(m)), Int(APPEND_ERR), m
        )
    print("  PASS")


def test_a_cloud_412_is_still_a_lost_slot() raises:
    print("[ts-412] a cloud 412 is still a lost slot")
    var backing = SharedInMemoryConditionalStore()
    var reader = TableStoreHeadReader[_Store](_wal(backing, "ts412/r2"))
    var app = TableStoreExactSlotAppender[_Store](_wal(backing, "ts412/a2"))
    var errs = _cloud_412s()
    for i in range(len(errs)):
        var m = errs[i]
        assert_true(_is_lost_slot_412(m), msg="_is_lost_slot_412: " + m)
        assert_equal(
            Int(reader.classify_read_error(m)), Int(READ_ERR_CONFLICT), m
        )
        assert_equal(
            Int(app.classify_append_error(m)), Int(APPEND_LOST_SLOT), m
        )
    print("  PASS")


def main() raises:
    test_an_io_error_whose_path_spells_412_is_not_a_lost_slot()
    test_a_cloud_412_is_still_a_lost_slot()
    print("ALL table-store lost-slot anchoring tests PASSED")
