# =============================================================================
# tests/test_local_fs_conditional_store.mojo
#   LocalFsConditionalStore — DETERMINISTIC, NETWORK-FREE conformance +
# real-CAS-semantics + DURABILITY-ACROSS-RESTART gate.
# =============================================================================
#
# Unlike the S3 conformer (whose happy path needs a live MinIO), the local-FS
# store runs its ENTIRE conditional-write lifecycle on plain local disk with NO
# network — so this test is a FULL behavioral gate, not just a wiring proof:
#
#   * COMPILE-TIME conformance: `_accept_*` generic bounds elaborate iff the
#     store resolves the full CloneableConditionalWriteStore surface (the
#     "compiling IS the proof" pattern). A missing/mismatched verb fails to
#     compile here.
#   * REAL CAS SEMANTICS: create-if-absent (412 on a second create), If-Match
#     CAS (advance + stale-etag 412), unconditional put-overwrite, get /
#     get_range / head / delete / list_with_delimiter — all exercised against
#     real files and asserted byte-exact.
#   * KEY CODEC: a key with `/` round-trips through the flat percent-encoding
#     to one filename and back (the durability invariant — same key → same file
#     across runs).
#   * CLONE SHARES BACKING: a clone writes a key the original reads back (the
#     KgSnapshotStore store-sharing seam — the filesystem IS the shared store).
#   * DURABILITY ACROSS RESTART: write objects, DROP the store, construct a
#     NEW store on the SAME root dir (the Electron-relaunch), and read every
#     object back byte-exact. This is the headline proof the personal KG
#     survives a process restart with NO MinIO.
#   * MANIFEST-ON-DISK: drive the SHARED `CasManifestStore[LocalFsConditionalStore]`
#     append → read_head → read_chunk loop (the EXACT seam KgSnapshotStore rides)
#     and prove it reads back across a restart — the linearizable-append CAS
#     protocol runs unchanged over the local-FS backend.
#
# All tests are DETERMINISTIC + always-run (no MLX, no MinIO, no network). They
# use a per-process-unique /tmp directory and clean it up (best-effort).
# =============================================================================

from std.time import perf_counter_ns

from std.testing import assert_equal, assert_false, assert_true

from komira_objectstore.cas_manifest import CasManifestStore, RetryPolicy
from komira_objectstore.local_fs_conditional_store import (
    LocalFsConditionalStore,
)
from komira_objectstore.path import Path
from komira_objectstore.store import (
    CloneableConditionalWriteStore,
    ConditionalWriteStore,
    ObjectStore,
)
from komira_objectstore.types import WritePrecondition
from komira_runtime_paths import test_tmpdir


# ---------------------------------------------------------------------------
# ⚠ $TEST_TMPDIR (through `test_tmpdir()`), NOT A HARD-CODED `/tmp` PATH.
#
# The same test may run in more than one action at a time on one machine. A
# fixed `/tmp` path is shared by every one of those executions; the runner's
# `TEST_TMPDIR` is private to each run, which is what makes them disjoint.
# `test_tmpdir()` raises when it is unset rather than fall back to `/tmp`.
# ---------------------------------------------------------------------------
def _scratch_dir() raises -> String:
    """The directory THIS execution may write scratch files into."""
    return test_tmpdir()


# -----------------------------------------------------------------------------
# A per-process-unique scratch root under /tmp (the test_kg_capture_loop_e2e
# nonce shape). Each test_* gets a distinct subdir so they never collide.
# -----------------------------------------------------------------------------
def _scratch_root(tag: String) raises -> String:
    var t = UInt64(perf_counter_ns())
    return (
        (_scratch_dir() + String("/komira_localfs_store_"))
        + tag
        + String("_")
        + String(t)
    )


def _bytes_from(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    var b = s.as_bytes()
    for i in range(len(b)):
        out.append(b[i])
    return out^


def _bytes_with_nuls(n: Int) -> List[UInt8]:
    """A buffer with interior NUL bytes — proves the byte-safe write/read path
    (parquet object bytes contain NULs)."""
    var out = List[UInt8]()
    var i = 0
    while i < n:
        out.append(UInt8(i % 3))  # 0,1,2,0,1,2,... (interior 0x00s)
        i += 1
    return out^


def _bytes_eq(a: List[UInt8], b: List[UInt8]) -> Bool:
    if len(a) != len(b):
        return False
    for i in range(len(a)):
        if a[i] != b[i]:
            return False
    return True


# -----------------------------------------------------------------------------
# COMPILE-TIME conformance witnesses — elaborate iff the store resolves the full
# trait surface (the "compiling IS the proof" pattern).
# -----------------------------------------------------------------------------
def _accept_object_store[S: ObjectStore](store: S) -> Int:
    return 1


def _accept_conditional_store[S: ConditionalWriteStore](store: S) -> Int:
    return 1


def _accept_cloneable[S: CloneableConditionalWriteStore](store: S) -> Int:
    return 1


def test_conformance_compiles() raises:
    """COMPILE-TIME PROOF: LocalFsConditionalStore is accepted by all three
    refining bounds — ObjectStore, ConditionalWriteStore, and
    CloneableConditionalWriteStore (the exact bound KgSnapshotStore /
    CasManifestStore require). If any verb were missing this would not
    compile."""
    var root = _scratch_root(String("conf"))
    var store = LocalFsConditionalStore(root.copy())
    assert_equal(_accept_object_store(store), 1)
    assert_equal(_accept_conditional_store(store), 1)
    assert_equal(_accept_cloneable(store), 1)
    _ = store^
    _cleanup(root)


def test_put_get_roundtrip_byte_exact() raises:
    """put → get round-trips bytes byte-exact, including interior NULs."""
    var root = _scratch_root(String("putget"))
    var store = LocalFsConditionalStore(root.copy())
    var key = Path.parse(String("objects/abc123.parquet"))
    var payload = _bytes_with_nuls(257)
    var meta = store.put(key, payload.copy())
    assert_equal(meta.size, Int64(257))
    var got = store.get(key)
    assert_true(_bytes_eq(got, payload))
    _ = store^
    _cleanup(root)


def test_head_reports_size_and_etag() raises:
    var root = _scratch_root(String("head"))
    var store = LocalFsConditionalStore(root.copy())
    var key = Path.parse(String("k/file.bin"))
    _ = store.put(key, _bytes_from(String("hello world")))
    var meta = store.head(key)
    assert_equal(meta.size, Int64(11))
    assert_true(meta.etag.byte_length() > 0)  # content-hash etag, non-empty
    # head etag must equal a fresh put's etag for identical bytes (S3 ETag
    # is the content hash).
    var meta2 = store.put(key, _bytes_from(String("hello world")))
    assert_equal(meta.etag, meta2.etag)
    _ = store^
    _cleanup(root)


def test_get_missing_raises_not_found() raises:
    """get on an absent key raises a not_found(404)-tagged Error — the message
    substring the CasManifestStore `_is_not_found` classifier matches on."""
    var root = _scratch_root(String("missing"))
    var store = LocalFsConditionalStore(root.copy())
    var raised = False
    try:
        var _b = store.get(Path.parse(String("nope/absent.dat")))
    except e:
        raised = True
        var msg = String(e)
        assert_true(msg.find(String("not_found")) >= 0 or msg.find(String("404")) >= 0)
    assert_true(raised)
    _ = store^
    _cleanup(root)


def test_create_if_absent_then_412() raises:
    """If-None-Match create-if-absent: first create wins; a SECOND create on
    the same key raises a precondition(412)-tagged Error (the slot-race loser).
    This is the manifest-append linearization point."""
    var root = _scratch_root(String("create"))
    var store = LocalFsConditionalStore(root.copy())
    var key = Path.parse(String("manifest/00000000000000000000.chunk"))
    var m = store.conditional_put(
        key, _bytes_from(String("chunk-0")), WritePrecondition.if_none_match_star()
    )
    assert_equal(m.size, Int64(7))
    var raised = False
    try:
        var _m2 = store.conditional_put(
            key, _bytes_from(String("chunk-0-again")),
            WritePrecondition.if_none_match_star(),
        )
    except e:
        raised = True
        var msg = String(e)
        assert_true(
            msg.find(String("precondition")) >= 0 or msg.find(String("412")) >= 0
        )
    assert_true(raised)
    # The original bytes survive the rejected second create.
    assert_true(_bytes_eq(store.get(key), _bytes_from(String("chunk-0"))))
    _ = store^
    _cleanup(root)


def test_if_match_cas_advance_and_stale_412() raises:
    """If-Match CAS: an advance with the CURRENT etag succeeds; an advance with
    a STALE etag raises precondition(412). This is the `_HEAD` advance."""
    var root = _scratch_root(String("cas"))
    var store = LocalFsConditionalStore(root.copy())
    var key = Path.parse(String("_HEAD"))
    var v0 = store.put(key, _bytes_from(String("head-v0")))
    # CAS with the current etag -> succeeds, returns a NEW etag.
    var v1 = store.compare_and_swap(key, _bytes_from(String("head-v1")), v0.etag)
    assert_true(v1.etag != v0.etag)
    assert_true(_bytes_eq(store.get(key), _bytes_from(String("head-v1"))))
    # CAS with the now-STALE v0 etag -> 412.
    var raised = False
    try:
        var _v = store.compare_and_swap(
            key, _bytes_from(String("head-v2-bad")), v0.etag
        )
    except e:
        raised = True
        var msg = String(e)
        assert_true(
            msg.find(String("precondition")) >= 0 or msg.find(String("412")) >= 0
        )
    assert_true(raised)
    # The v1 bytes survive the rejected stale CAS.
    assert_true(_bytes_eq(store.get(key), _bytes_from(String("head-v1"))))
    _ = store^
    _cleanup(root)


def test_if_match_on_absent_raises_412() raises:
    var root = _scratch_root(String("casabsent"))
    var store = LocalFsConditionalStore(root.copy())
    var raised = False
    try:
        var _m = store.compare_and_swap(
            Path.parse(String("never")), _bytes_from(String("x")), String('"deadbeef"')
        )
    except e:
        raised = True
    assert_true(raised)
    _ = store^
    _cleanup(root)


def test_get_range_subwindow() raises:
    var root = _scratch_root(String("range"))
    var store = LocalFsConditionalStore(root.copy())
    var key = Path.parse(String("seg/0001.dat"))
    _ = store.put(key, _bytes_from(String("0123456789")))
    var win = store.get_range(key, Int64(3), Int64(4))  # "3456"
    assert_true(_bytes_eq(win, _bytes_from(String("3456"))))
    # Zero-length is a no-op (empty).
    var empty = store.get_range(key, Int64(0), Int64(0))
    assert_equal(len(empty), 0)
    # Out-of-range raises.
    var raised = False
    try:
        var _w = store.get_range(key, Int64(8), Int64(99))
    except e:
        raised = True
    assert_true(raised)
    _ = store^
    _cleanup(root)


def test_delete_is_idempotent() raises:
    var root = _scratch_root(String("del"))
    var store = LocalFsConditionalStore(root.copy())
    var key = Path.parse(String("doomed/x.dat"))
    _ = store.put(key, _bytes_from(String("bye")))
    store.delete(key)  # removes it
    # get now 404s.
    var raised = False
    try:
        var _b = store.get(key)
    except:
        raised = True
    assert_true(raised)
    # delete again on an ABSENT key succeeds (idempotent, S3 semantics).
    store.delete(key)
    _ = store^
    _cleanup(root)


def test_list_with_delimiter_prefix_match() raises:
    """list_with_delimiter returns objects whose key starts with the prefix —
    the recovery/discovery surface. Keys with `/` are flat-encoded but DECODE
    back to their real keys for the prefix match."""
    var root = _scratch_root(String("list"))
    var store = LocalFsConditionalStore(root.copy())
    _ = store.put(Path.parse(String("manifest/00000000000000000000.chunk")), _bytes_from(String("a")))
    _ = store.put(Path.parse(String("manifest/00000000000000000001.chunk")), _bytes_from(String("bb")))
    _ = store.put(Path.parse(String("objects/deadbeef.parquet")), _bytes_from(String("ccc")))
    # Prefix "manifest" matches exactly the two chunk keys.
    var res = store.list_with_delimiter(Path.parse(String("manifest")))
    assert_equal(len(res.objects), 2)
    # The decoded keys carry the real `/`-delimited key (not the flat fname).
    var saw_chunk0 = False
    var saw_chunk1 = False
    for i in range(len(res.objects)):
        var loc = res.objects[i].location
        if loc == String("manifest/00000000000000000000.chunk"):
            saw_chunk0 = True
        if loc == String("manifest/00000000000000000001.chunk"):
            saw_chunk1 = True
    assert_true(saw_chunk0)
    assert_true(saw_chunk1)
    # Empty prefix matches everything (3 objects).
    var all = store.list_with_delimiter(Path.parse(String("")))
    assert_equal(len(all.objects), 3)
    _ = store^
    _cleanup(root)


def test_clone_shares_filesystem_backing() raises:
    """A clone writes a key the ORIGINAL reads back — both reach the same files
    (the KgSnapshotStore store-sharing seam: the filesystem IS the shared
    backing store)."""
    var root = _scratch_root(String("clone"))
    var store = LocalFsConditionalStore(root.copy())
    var sibling = store.clone()
    assert_equal(sibling.root(), store.root())
    var key = Path.parse(String("shared/k.dat"))
    _ = sibling.put(key, _bytes_from(String("written-by-clone")))
    # The ORIGINAL handle reads back the clone's write.
    assert_true(_bytes_eq(store.get(key), _bytes_from(String("written-by-clone"))))
    _ = sibling^
    _ = store^
    _cleanup(root)


def test_durability_across_restart() raises:
    """THE HEADLINE: write objects, DROP the store (process exit), construct a
    NEW store on the SAME root dir (Electron-relaunch), read every object back
    byte-exact. Proves the personal KG survives a restart with NO MinIO."""
    var root = _scratch_root(String("durable"))
    var payload_a = _bytes_with_nuls(513)
    var payload_b = _bytes_from(String("manifest-head-bytes"))

    # ---- "process 1": write, then DROP the store. ----
    var store1 = LocalFsConditionalStore(root.copy())
    _ = store1.put(Path.parse(String("objects/a.parquet")), payload_a.copy())
    _ = store1.conditional_put(
        Path.parse(String("manifest/_HEAD")), payload_b.copy(),
        WritePrecondition.if_none_match_star(),
    )
    _ = store1^  # explicit drop — the store handle is gone, only files remain.

    # ---- "process 2": fresh store on the SAME dir reads it all back. ----
    var store2 = LocalFsConditionalStore(root.copy())
    assert_true(
        _bytes_eq(store2.get(Path.parse(String("objects/a.parquet"))), payload_a)
    )
    assert_true(
        _bytes_eq(store2.get(Path.parse(String("manifest/_HEAD"))), payload_b)
    )
    # And a create-if-absent on the surviving key still 412s (the file is
    # durably present across the restart).
    var raised = False
    try:
        var _m = store2.conditional_put(
            Path.parse(String("manifest/_HEAD")), _bytes_from(String("x")),
            WritePrecondition.if_none_match_star(),
        )
    except:
        raised = True
    assert_true(raised)
    _ = store2^
    _cleanup(root)


def test_cas_manifest_append_read_on_disk_and_restart() raises:
    """Drive the SHARED CasManifestStore[LocalFsConditionalStore] append loop —
    the EXACT manifest seam KgSnapshotStore rides — on local disk, then prove a
    fresh store on the same dir reads the appended chunks back across a restart.
    The linearizable-append CAS protocol runs UNCHANGED over the FS backend."""
    var root = _scratch_root(String("manifest"))
    var prefix = String("kg/lineage")

    # ---- "process 1": append two chunks via the real CAS append loop. ----
    var store1 = LocalFsConditionalStore(root.copy())
    var manifest1 = CasManifestStore[LocalFsConditionalStore](
        store1^, prefix.copy(), RetryPolicy.fast_test()
    )
    var head0 = manifest1.read_head()
    assert_equal(head0.chunk_seq, Int64(-1))  # empty lineage
    var r0 = manifest1.append(_bytes_from(String("snapshot-0-body")), Int64(2))
    assert_equal(r0.chunk_seq, Int64(0))
    var r1 = manifest1.append(_bytes_from(String("snapshot-1-body")), Int64(3))
    assert_equal(r1.chunk_seq, Int64(1))
    var head_after = manifest1.read_head()
    assert_equal(head_after.chunk_seq, Int64(1))
    _ = manifest1^  # DROP the manifest + its store handle.

    # ---- "process 2": fresh store + manifest on the SAME dir reads back. ----
    var store2 = LocalFsConditionalStore(root.copy())
    var manifest2 = CasManifestStore[LocalFsConditionalStore](
        store2^, prefix.copy(), RetryPolicy.fast_test()
    )
    var head2 = manifest2.read_head_authoritative()
    assert_equal(head2.chunk_seq, Int64(1))  # both chunks durable across restart
    assert_true(
        _bytes_eq(manifest2.read_chunk(Int64(0)), _bytes_from(String("snapshot-0-body")))
    )
    assert_true(
        _bytes_eq(manifest2.read_chunk(Int64(1)), _bytes_from(String("snapshot-1-body")))
    )
    # A third append continues the gapless sequence (the bucket-is-truth tail).
    var r2 = manifest2.append(_bytes_from(String("snapshot-2-body")), Int64(1))
    assert_equal(r2.chunk_seq, Int64(2))
    _ = manifest2^
    _cleanup(root)


def test_key_codec_roundtrips() raises:
    """A key with `/` (and other non-safe bytes) flat-encodes to one filename
    and the listing decodes it back — the durability invariant (same key →
    same file across runs)."""
    var root = _scratch_root(String("codec"))
    var store = LocalFsConditionalStore(root.copy())
    var key = Path.parse(String("a/b/c/file-name_v1.2.parquet"))
    _ = store.put(key, _bytes_from(String("payload")))
    # The listing decodes the flat filename back to the exact key.
    var res = store.list_with_delimiter(Path.parse(String("")))
    assert_equal(len(res.objects), 1)
    assert_equal(
        res.objects[0].location, String("a/b/c/file-name_v1.2.parquet")
    )
    # And a re-open reads the same key back (deterministic encoding).
    _ = store^
    var store2 = LocalFsConditionalStore(root.copy())
    assert_true(_bytes_eq(store2.get(key), _bytes_from(String("payload"))))
    _ = store2^
    _cleanup(root)


def _cleanup(root: String):
    """Best-effort recursive cleanup of the scratch dir via the in-store delete
    of every listed object + the dir. A leftover /tmp dir is a janitor concern,
    not a correctness one; failures are swallowed."""
    try:
        var store = LocalFsConditionalStore(root.copy())
        var res = store.list_with_delimiter(Path.parse(String("")))
        for i in range(len(res.objects)):
            store.delete(Path.parse(res.objects[i].location))
        _ = store^
    except:
        pass


def main() raises:
    test_conformance_compiles()
    test_put_get_roundtrip_byte_exact()
    test_head_reports_size_and_etag()
    test_get_missing_raises_not_found()
    test_create_if_absent_then_412()
    test_if_match_cas_advance_and_stale_412()
    test_if_match_on_absent_raises_412()
    test_get_range_subwindow()
    test_delete_is_idempotent()
    test_list_with_delimiter_prefix_match()
    test_clone_shares_filesystem_backing()
    test_durability_across_restart()
    test_cas_manifest_append_read_on_disk_and_restart()
    test_key_codec_roundtrips()
    print("[test_local_fs_conditional_store] all 14 tests PASS")
