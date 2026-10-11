# =============================================================================
# tests/test_cas_gate_released_once_offline.mojo
#   A failed `_LOG_START` / `_CATALOG` read releases the CAS gate exactly once
#   (komira-ai/komira#1087).
# =============================================================================
#
# `read_log_start` and `read_catalog_sidecar` take the process-wide CAS gate's
# read lock. When the store's GET fails with an error that is not a 404 (a
# 403, a 5xx), each verb must raise that error and release the lock once. A
# second release drives the rwlock's reader count below zero, and from then
# on every write-locked verb in the process (`advance_log_start`,
# `cas_catalog_sidecar`, `reap`, ...) blocks forever, on any manifest.
#
# Each test fails one GET with a 403-shaped message, checks the verb raises
# exactly that error, then runs a write-locked verb on an UNRELATED manifest
# and store. A double release shows up as that write never returning: the
# watchdog `alarm` below kills the process (SIGALRM) instead of letting the
# build action hang. A test that leaked the lock (no release at all) is
# caught the same way.
#
# The absent-object halves (404 reads as zero / absent, and the gate is
# still free afterwards) run too, so a fix that made every error raise, or
# every error read as absent, also fails here.
# =============================================================================

from std.ffi import external_call
from std.testing import assert_equal, assert_false, assert_raises, assert_true

from komira_objectstore.cas_manifest import (
    CasManifestStore,
    RetryPolicy,
    catalog_key,
    log_start_key,
)
from komira_objectstore.path import Path
from komira_objectstore.shared_in_memory_conditional_store import (
    SharedInMemoryConditionalStore,
)
from komira_objectstore.store import ConditionalWriteStore, ObjectStore
from komira_objectstore.types import (
    CoalescePolicy,
    ListResult,
    ObjectMeta,
    WritePrecondition,
)

comptime _ERR = "StoreError[PERMISSION_DENIED] status=403 injected"
# Seconds before the watchdog kills a test whose gated write never returns.
# Every write here takes microseconds; the margin covers coverage builds.
comptime _WATCHDOG_S = 60


struct _GetFault(ConditionalWriteStore, ObjectStore, Movable, Deinitable):
    """A shared in-memory store whose GET of exactly `fail_key` raises `_ERR`.
    Every other verb and key goes to the inner store."""

    var inner: SharedInMemoryConditionalStore
    var fail_key: String

    def __init__(out self, var fail_key: String):
        self.inner = SharedInMemoryConditionalStore()
        self.fail_key = fail_key^

    def head(self, path: Path) raises -> ObjectMeta:
        return self.inner.head(path)

    def list_with_delimiter(self, prefix: Path) raises -> ListResult:
        return self.inner.list_with_delimiter(prefix)

    def coalesce_policy(self) -> CoalescePolicy:
        return self.inner.coalesce_policy()

    def conditional_put(
        self, path: Path, bytes: List[UInt8], precond: WritePrecondition
    ) raises -> ObjectMeta:
        return self.inner.conditional_put(path, bytes, precond)

    def compare_and_swap(
        self, path: Path, bytes: List[UInt8], expected_version: String
    ) raises -> ObjectMeta:
        return self.inner.compare_and_swap(path, bytes, expected_version)

    def put(self, path: Path, bytes: List[UInt8]) raises -> ObjectMeta:
        return self.inner.put(path, bytes)

    def get_range(
        self, path: Path, start: Int64, length: Int64
    ) raises -> List[UInt8]:
        return self.inner.get_range(path, start, length)

    def get(self, path: Path) raises -> List[UInt8]:
        if path.raw() == self.fail_key:
            raise Error(_ERR)
        return self.inner.get(path)

    def delete(self, path: Path) raises -> None:
        self.inner.delete(path)


comptime _Shared = CasManifestStore[SharedInMemoryConditionalStore]


def _other(prefix: String) -> _Shared:
    """A manifest on its own store: it shares nothing with the faulted one
    except the process-wide gate."""
    return _Shared(
        store=SharedInMemoryConditionalStore(),
        prefix=prefix,
        retry=RetryPolicy.fast_test(),
    )


def _blob(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    for b in s.as_bytes():
        out.append(b)
    return out^


def _arm_watchdog():
    # SIGALRM's default action terminates the process: a gated write that
    # blocks forever fails the test instead of hanging the build.
    _ = external_call["alarm", UInt32](UInt32(_WATCHDOG_S))


def test_log_start_error_releases_gate_once() raises:
    print("[gate] read_log_start: a 403 raises, and the gate is free after")
    var p = String("g/ls")
    var m = CasManifestStore[_GetFault](
        store=_GetFault(log_start_key(p).raw()),
        prefix=p,
        retry=RetryPolicy.fast_test(),
    )
    with assert_raises(contains=_ERR):
        _ = m.read_log_start()
    # The same verb again: a gate left held for write, or released below
    # zero, would block or misbehave here before the write below.
    with assert_raises(contains=_ERR):
        _ = m.read_log_start()
    print("  write-locked verb on another manifest (blocks if released twice)")
    var o = _other(String("g/ls-other"))
    var ls = o.advance_log_start(Int64(1), Int64(1), String(""))
    assert_equal(ls.log_start_seq, Int64(1))
    assert_true(ls.etag.byte_length() > 0, "advance returned the new etag")
    print("  PASS")


def test_catalog_error_releases_gate_once() raises:
    print("[gate] read_catalog_sidecar: a 403 raises, and the gate is free after")
    var p = String("g/cat")
    var m = CasManifestStore[_GetFault](
        store=_GetFault(catalog_key(p).raw()),
        prefix=p,
        retry=RetryPolicy.fast_test(),
    )
    with assert_raises(contains=_ERR):
        _ = m.read_catalog_sidecar()
    with assert_raises(contains=_ERR):
        _ = m.read_catalog_sidecar()
    print("  write-locked verb on another manifest (blocks if released twice)")
    var o = _other(String("g/cat-other"))
    var sc = o.cas_catalog_sidecar(_blob("v1"), String(""))
    assert_true(sc.present, "the catalog write landed")
    print("  PASS")


def test_absent_objects_read_empty_and_release_gate() raises:
    print("[gate] absent _LOG_START / _CATALOG read as zero / absent")
    var p = String("g/absent")
    var m = _other(p)
    var ls = m.read_log_start()
    assert_equal(ls.log_start_seq, Int64(0))
    assert_equal(ls.log_start_offset, Int64(0))
    assert_equal(ls.etag, String(""))
    var sc = m.read_catalog_sidecar()
    assert_false(sc.present, "an absent catalog reads as absent")
    # Both reads released the gate: the writes below take it exclusively.
    var adv = m.advance_log_start(Int64(2), Int64(5), String(""))
    assert_equal(m.read_log_start().log_start_offset, Int64(5))
    assert_equal(m.read_log_start().etag, adv.etag)
    var w = m.cas_catalog_sidecar(_blob("v1"), String(""))
    assert_equal(m.read_catalog_sidecar().etag, w.etag)
    print("  PASS")


def main() raises:
    _arm_watchdog()
    test_absent_objects_read_empty_and_release_gate()
    test_log_start_error_releases_gate_once()
    test_catalog_error_releases_gate_once()
    print("ALL cas-gate release tests PASSED")
