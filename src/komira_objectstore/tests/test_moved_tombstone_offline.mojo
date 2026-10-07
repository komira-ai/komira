# =============================================================================
# tests/test_moved_tombstone_offline.mojo
#   MOVED markers on the CAS manifest — OFFLINE
# =============================================================================
#
# `schedule_moved_for_delete_at` retires a chunk whose payload another
# manifest now references, at `<prefix>/moved_tombstones/<seq>.tomb`, a key no
# other verb writes. The manifest tests run on the delimiter-faithful store,
# whose LIST of `<prefix>/` returns only direct children (as S3 does), so a
# verb that forgets the `moved_tombstones/` prefix is caught.
#
#   (1) Write and read. A MOVED marker reads back its ts; a chunk without one
#       reads None; a later plain tombstone on the same chunk leaves the MOVED
#       marker as it was (no downgrade); a rewrite refreshes its ts; a chunk
#       that does not exist raises not_found. `tombstone_seqs` lists plain,
#       moved and both (once each), ascending; `moved_tombstone_seqs` lists
#       the moved ones. Catches: `tombstone_seqs` missing the moved prefix, a
#       duplicate seq, a moved write that lands on the plain key.
#   (2) `reap`. A chunk at or above `_LOG_START` with only a MOVED marker is
#       refused. Below it, a MOVED-only chunk is reaped (the MOVED marker
#       counts as ScheduledForDelete), and a chunk with both markers loses
#       both. A chunk with no marker is still refused.
#   (3) `purge_all` deletes MOVED markers too.
#   (4) Read errors that are not absence raise: from `moved_tombstone_ts`
#       (not taken for "no marker"), and from `reap`'s marker check.
# =============================================================================

from std.testing import assert_equal, assert_false, assert_true

from komira_objectstore.cas_manifest import (
    CasManifestStore,
    RetryPolicy,
    chunk_key,
    is_not_found,
    moved_tombstone_key,
    tombstone_key,
)
from komira_objectstore.delimiter_faithful_conditional_store import (
    DelimiterFaithfulConditionalStore,
)
from komira_objectstore.path import Path
from komira_objectstore.shared_in_memory_conditional_store import (
    SharedInMemoryConditionalStore,
)
from komira_objectstore.store import (
    CloneableConditionalWriteStore,
    ConditionalWriteStore,
    ObjectStore,
)
from komira_objectstore.types import (
    CoalescePolicy,
    ListResult,
    ObjectMeta,
    WritePrecondition,
)


comptime _Df = DelimiterFaithfulConditionalStore
comptime _Inner = SharedInMemoryConditionalStore
comptime _PREFIX = "movedmark/_meta/topics/t/0"
comptime _FAIL_GET = "__fault__/get/"


def _df_manifest(store: _Df) -> CasManifestStore[_Df]:
    return CasManifestStore[_Df](
        store=store.clone(), prefix=String(_PREFIX), retry=RetryPolicy.fast_test()
    )


def _append_n(mut m: CasManifestStore[_Df], n: Int) raises:
    for _ in range(n):
        var body = List[UInt8]()
        body.append(UInt8(9))
        _ = m.append(body^, Int64(1))


def _df_has(store: _Df, key: Path) -> Bool:
    try:
        _ = store.head(key)
        return True
    except:
        return False


def _assert_seqs(got: List[Int64], want: List[Int64], what: String) raises:
    assert_equal(len(got), len(want), what + ": count")
    for i in range(len(want)):
        assert_equal(got[i], want[i], what + ": seq " + String(i))


# =============================================================================
# (1) write and read
# =============================================================================


def test_moved_marker_write_and_read() raises:
    print("[test_moved_marker_write_and_read] starting...")
    var store = _Df()
    var m = _df_manifest(store)
    _append_n(m, 4)

    assert_false(Bool(m.moved_tombstone_ts(Int64(0))), "no marker: None")

    m.schedule_moved_for_delete_at(Int64(1), Int64(5000))
    assert_equal(m.moved_tombstone_ts(Int64(1)).value(), Int64(5000), "ts")
    assert_true(
        _df_has(store, moved_tombstone_key(String(_PREFIX), Int64(1))), "moved key"
    )
    assert_false(
        _df_has(store, tombstone_key(String(_PREFIX), Int64(1))), "no plain key"
    )

    # A later plain tombstone does not touch the MOVED marker.
    m.schedule_for_delete_at(Int64(1), Int64(9000))
    assert_equal(
        m.moved_tombstone_ts(Int64(1)).value(), Int64(5000), "not downgraded"
    )
    assert_equal(m.tombstone_schedule_ts(Int64(1)), Int64(9000), "plain ts")

    m.schedule_for_delete_at(Int64(2), Int64(7000))
    m.schedule_moved_for_delete_at(Int64(3), Int64(6000))
    m.schedule_moved_for_delete_at(Int64(3), Int64(8000))
    assert_equal(m.moved_tombstone_ts(Int64(3)).value(), Int64(8000), "rewrite")

    _assert_seqs(m.tombstone_seqs(), [Int64(1), Int64(2), Int64(3)], "all")
    _assert_seqs(m.moved_tombstone_seqs(), [Int64(1), Int64(3)], "moved")

    var raised = False
    try:
        m.schedule_moved_for_delete_at(Int64(9), Int64(1))
    except e:
        raised = True
        assert_true(is_not_found(String(e)), String(e))
    assert_true(raised, "no chunk 9: not_found")
    _ = m^
    print("[test_moved_marker_write_and_read] PASS")


# =============================================================================
# (2) reap
# =============================================================================


def test_reap_with_moved_markers() raises:
    print("[test_reap_with_moved_markers] starting...")
    var store = _Df()
    var m = _df_manifest(store)
    _append_n(m, 4)
    m.schedule_moved_for_delete_at(Int64(1), Int64(5000))
    m.schedule_for_delete_at(Int64(1), Int64(5000))
    m.schedule_moved_for_delete_at(Int64(2), Int64(5000))

    var refused = False
    try:
        m.reap(Int64(2))
    except e:
        refused = True
        assert_true(String(e).find("refused") >= 0, String(e))
    assert_true(refused, "a live chunk with a MOVED marker is refused")
    assert_true(_df_has(store, chunk_key(String(_PREFIX), Int64(2))), "kept")

    var ls = m.read_log_start()
    _ = m.advance_log_start(Int64(3), Int64(3), ls.etag)

    m.reap(Int64(2))  # MOVED only
    assert_false(_df_has(store, chunk_key(String(_PREFIX), Int64(2))), "chunk 2")
    assert_false(
        _df_has(store, moved_tombstone_key(String(_PREFIX), Int64(2))), "marker 2"
    )
    m.reap(Int64(1))  # both
    assert_false(_df_has(store, chunk_key(String(_PREFIX), Int64(1))), "chunk 1")
    assert_false(
        _df_has(store, moved_tombstone_key(String(_PREFIX), Int64(1))), "moved 1"
    )
    assert_false(
        _df_has(store, tombstone_key(String(_PREFIX), Int64(1))), "plain 1"
    )
    var raised = False
    try:
        m.reap(Int64(0))
    except e:
        raised = True
        assert_true(String(e).find("not ScheduledForDelete") >= 0, String(e))
    assert_true(raised, "no marker: refused")
    assert_equal(len(m.tombstone_seqs()), 0, "no marker left")
    _ = m^
    print("[test_reap_with_moved_markers] PASS")


# =============================================================================
# (3) purge_all
# =============================================================================


def test_purge_all_deletes_moved_markers() raises:
    print("[test_purge_all_deletes_moved_markers] starting...")
    var store = _Df()
    var m = _df_manifest(store)
    _append_n(m, 2)
    m.schedule_moved_for_delete_at(Int64(0), Int64(5000))
    m.schedule_for_delete_at(Int64(1), Int64(5000))
    _ = m.purge_all()
    assert_false(
        _df_has(store, moved_tombstone_key(String(_PREFIX), Int64(0))), "moved"
    )
    assert_false(
        _df_has(store, tombstone_key(String(_PREFIX), Int64(1))), "plain"
    )
    assert_equal(len(m.moved_tombstone_seqs()), 0, "no moved marker")
    assert_equal(len(m.tombstone_seqs()), 0, "no marker")
    _ = m^
    print("[test_purge_all_deletes_moved_markers] PASS")


# =============================================================================
# (4) read errors
# =============================================================================


def _inner_has(inner: _Inner, key: String) -> Bool:
    try:
        _ = inner.head(Path.parse(key))
        return True
    except:
        return False


struct _FailGetStore(
    CloneableConditionalWriteStore,
    ConditionalWriteStore,
    ObjectStore,
    Movable,
    Deinitable,
):
    """A shared in-memory store whose GET of an armed key fails with an error
    that is not absence."""

    var _inner: _Inner

    def __init__(out self, var inner: _Inner):
        self._inner = inner^

    def clone(self) -> Self:
        return Self(self._inner.clone())

    def arm(self, target: Path) raises:
        _ = self._inner.put(Path.parse(String(_FAIL_GET) + target.raw()), List[UInt8]())

    def head(self, path: Path) raises -> ObjectMeta:
        return self._inner.head(path)

    def list_with_delimiter(self, prefix: Path) raises -> ListResult:
        return self._inner.list_with_delimiter(prefix)

    def coalesce_policy(self) -> CoalescePolicy:
        return self._inner.coalesce_policy()

    def get_range(
        self, path: Path, start: Int64, length: Int64
    ) raises -> List[UInt8]:
        return self._inner.get_range(path, start, length)

    def get(self, path: Path) raises -> List[UInt8]:
        if _inner_has(self._inner, String(_FAIL_GET) + path.raw()):
            raise Error("injected fault: transport error status=503")
        return self._inner.get(path)

    def conditional_put(
        self, path: Path, bytes: List[UInt8], precond: WritePrecondition
    ) raises -> ObjectMeta:
        return self._inner.conditional_put(path, bytes, precond)

    def compare_and_swap(
        self, path: Path, bytes: List[UInt8], expected_version: String
    ) raises -> ObjectMeta:
        return self._inner.compare_and_swap(path, bytes, expected_version)

    def put(self, path: Path, bytes: List[UInt8]) raises -> ObjectMeta:
        return self._inner.put(path, bytes)

    def delete(self, path: Path) raises -> None:
        self._inner.delete(path)


def test_read_errors_raise() raises:
    print("[test_read_errors_raise] starting...")
    var store = _FailGetStore(_Inner())
    var m = CasManifestStore[_FailGetStore](
        store=store.clone(), prefix=String(_PREFIX), retry=RetryPolicy.fast_test()
    )
    for _ in range(2):
        var body = List[UInt8]()
        body.append(UInt8(9))
        _ = m.append(body^, Int64(1))
    m.schedule_moved_for_delete_at(Int64(0), Int64(5000))
    store.arm(moved_tombstone_key(String(_PREFIX), Int64(0)))
    var raised = False
    try:
        _ = m.moved_tombstone_ts(Int64(0))
    except e:
        raised = True
        assert_true(String(e).find("503") >= 0, String(e))
    assert_true(raised, "a failed read is not 'no marker'")

    store.arm(tombstone_key(String(_PREFIX), Int64(1)))
    var raised2 = False
    try:
        m.reap(Int64(1))
    except e:
        raised2 = True
        assert_true(String(e).find("503") >= 0, String(e))
    assert_true(raised2, "reap's marker check raises a failed read")
    _ = m^
    print("[test_read_errors_raise] PASS")


def main() raises:
    test_moved_marker_write_and_read()
    test_reap_with_moved_markers()
    test_purge_all_deletes_moved_markers()
    test_read_errors_raise()
    print("[OK] test_moved_tombstone_offline — 4 cases passed")
