# =============================================================================
# src/komira_table_store/tests/test_table_store_correctness.mojo
#   Table-store correctness slice — the DETERMINISTIC invariant tests
#   (a),(b),(c),(e),(f) + the (d) deterministic discriminating variant.
# =============================================================================
#
# The single-thread, deterministic correctness proof of the storage core: each
# test pins exact snapshot LSNs and asserts exact bytes, so it is reproducible
# and belongs in the fast lane. Tests (b) and (d) are the DISCRIMINATING ones:
# they go RED on a naive "read-latest / append-without-OCC" implementation and
# GREEN only on the §3.4 design (see the discriminating-proof tests at the
# bottom, which exercise the property directly and would fail on the naive
# shape).
#
# Design: the table-store correctness-slice design §7.
#
# Runs against InMemoryConditionalStore (single-thread, deterministic) AND
# LocalFsConditionalStore (real filesystem — the durability/recovery test (e)
# is a TRUE crash-recovery test on disk).
# =============================================================================

from std.testing import assert_equal, assert_false, assert_true

from komira_objectstore.cas_manifest import (
    CasManifestStore,
    ManifestHead,
    RetryPolicy,
    chunk_key,
    encode_chunk,
    encode_head,
    head_key,
)
from komira_objectstore.in_memory_conditional_store import (
    InMemoryConditionalStore,
)
from komira_objectstore.types import WritePrecondition
from komira_objectstore.local_fs_conditional_store import (
    LocalFsConditionalStore,
)
from komira_objectstore.shared_in_memory_conditional_store import (
    SharedInMemoryConditionalStore,
)

from komira_table_store.key_index import KeyValue
from komira_table_store.table_store_codec import (
    PG_COMMIT_FORMAT_VERSION,
    PG_OP_PUT,
    PG_SCHEMA_VERSION_UNSET,
    WriteOp,
    bytes_eq,
    decode_commit_chunk,
    decode_commit_chunk_keys,
    encode_commit_chunk,
)
from komira_table_store.table_store import (
    CommitResult,
    TableStore,
    Txn,
    is_occ_conflict,
)
from komira_runtime_paths import test_tmpdir


def _scratch_dir() raises -> String:
    """The directory THIS execution may write scratch files into.

    `test_tmpdir()` is $TEST_TMPDIR, private to this run; it raises rather than
    falling back to a `/tmp` path that concurrent runs would share.
    """
    return test_tmpdir()


# =============================================================================
# Helpers
# =============================================================================


def _b(s: String) -> List[UInt8]:
    """String -> bytes (the test's key/row literals)."""
    var out = List[UInt8]()
    var sb = s.as_bytes()
    for i in range(len(sb)):
        out.append(sb[i])
    return out^


def _str(b: List[UInt8]) -> String:
    var out = String("")
    for i in range(len(b)):
        out += chr(Int(b[i]))
    return out^


def _new_mem_store(prefix: String) raises -> TableStore[InMemoryConditionalStore]:
    var wal = CasManifestStore[InMemoryConditionalStore](
        store=InMemoryConditionalStore(),
        prefix=prefix,
        retry=RetryPolicy.fast_test(),
    )
    return TableStore[InMemoryConditionalStore].open(wal^)


def _assert_some_eq(
    got: Optional[List[UInt8]], want: String, msg: String
) raises:
    assert_true(Bool(got), msg + " (expected Some, got None)")
    assert_true(bytes_eq(got.value(), _b(want)), msg + " (byte mismatch)")


def _assert_none(got: Optional[List[UInt8]], msg: String) raises:
    assert_false(Bool(got), msg + " (expected None / invisible)")


# A tiny single-write commit helper.
def _commit_put(
    mut ts: TableStore[InMemoryConditionalStore], k: String, v: String
) raises -> Int64:
    var t = ts.begin()
    t.insert(_b(k), _b(v))
    var r = ts.commit(t^)
    return r.commit_lsn


def _commit_delete(
    mut ts: TableStore[InMemoryConditionalStore], k: String
) raises -> Int64:
    var t = ts.begin()
    t.delete(_b(k))
    var r = ts.commit(t^)
    return r.commit_lsn


# =============================================================================
# (a) Commit atomicity — all-or-nothing, no torn read.
# =============================================================================


def test_a_commit_atomicity() raises:
    print("[a] commit atomicity (all-or-nothing)")
    var ts = _new_mem_store(String("pg/a"))

    # In-flight txn writing 3 keys; a SECOND txn pins the (empty) snapshot
    # BEFORE commit and must see NONE of the in-flight rows.
    var t = ts.begin()
    t.insert(_b("k1"), _b("r1"))
    t.insert(_b("k2"), _b("r2"))
    t.insert(_b("k3"), _b("r3"))

    var mid_reader = ts.begin()  # snapshot S0 = -1 (empty log)
    assert_equal(mid_reader.snapshot_lsn, Int64(-1), "mid reader pins empty")
    _assert_none(ts.get(mid_reader, _b("k1")), "mid reader: k1 invisible")
    _assert_none(ts.get(mid_reader, _b("k2")), "mid reader: k2 invisible")
    _assert_none(ts.get(mid_reader, _b("k3")), "mid reader: k3 invisible")

    var r = ts.commit(t^)
    assert_true(r.did_append, "commit appended a chunk")
    assert_equal(r.commit_lsn, Int64(0), "first commit wins slot 0")

    # Post-commit reader sees ALL three with exact bytes.
    var post = ts.begin()
    _assert_some_eq(ts.get(post, _b("k1")), "r1", "post: k1")
    _assert_some_eq(ts.get(post, _b("k2")), "r2", "post: k2")
    _assert_some_eq(ts.get(post, _b("k3")), "r3", "post: k3")

    # The mid reader (still pinned at S0) STILL sees none (snapshot stable).
    _assert_none(ts.get(mid_reader, _b("k1")), "mid reader stays empty (k1)")

    # An ABORTED txn leaves zero rows visible.
    var t2 = ts.begin()
    t2.insert(_b("k4"), _b("r4"))
    ts.abort(t2^)
    var post2 = ts.begin()
    _assert_none(ts.get(post2, _b("k4")), "aborted write never visible")
    print("    [OK] (a)")


# =============================================================================
# (b) Snapshot isolation — stable view across a concurrent commit.
#     DISCRIMINATING: a "read-latest" impl fails the second reader.get.
# =============================================================================


def test_b_snapshot_isolation() raises:
    print("[b] snapshot isolation (stable view) — DISCRIMINATING")
    var ts = _new_mem_store(String("pg/b"))

    var s0 = _commit_put(ts, String("k"), String("v0"))  # LSN 0
    assert_equal(s0, Int64(0), "v0 at LSN 0")

    var reader = ts.begin()  # pins S0 = 0
    assert_equal(reader.snapshot_lsn, Int64(0), "reader pins S0")
    _assert_some_eq(ts.get(reader, _b("k")), "v0", "reader first read = v0")

    # A separate writer commits (k, v1) at S1 = 1.
    var s1 = _commit_put(ts, String("k"), String("v1"))  # LSN 1
    assert_equal(s1, Int64(1), "v1 at LSN 1")

    # The reader pinned at S0 reads AGAIN — MUST still see v0 (NOT v1). This is
    # the discriminating assertion: a naive impl that returns the newest chain
    # entry (read-latest) returns v1 here and FAILS.
    _assert_some_eq(
        ts.get(reader, _b("k")), "v0", "reader SECOND read STILL = v0 (SI)"
    )

    # A fresh begin() (pins S1=1) sees v1.
    var fresh = ts.begin()
    assert_equal(fresh.snapshot_lsn, Int64(1), "fresh pins S1")
    _assert_some_eq(ts.get(fresh, _b("k")), "v1", "fresh read = v1")
    print("    [OK] (b)")


# =============================================================================
# (c) Read-your-own-writes.
# =============================================================================


def test_c_read_your_own_writes() raises:
    print("[c] read-your-own-writes")
    var ts = _new_mem_store(String("pg/c"))
    _ = _commit_put(ts, String("k"), String("v0"))  # LSN 0

    var t = ts.begin()
    _assert_some_eq(ts.get(t, _b("k")), "v0", "t sees committed v0")

    # Buffered update -> own write visible before commit.
    t.update(_b("k"), _b("v1"))
    _assert_some_eq(ts.get(t, _b("k")), "v1", "t sees its own buffered v1")

    # Buffered insert of a NEW key not in the snapshot.
    t.insert(_b("k2"), _b("v2"))
    _assert_some_eq(ts.get(t, _b("k2")), "v2", "t sees its own buffered k2")

    # Buffered delete of k -> own tombstone visible.
    t.delete(_b("k"))
    _assert_none(ts.get(t, _b("k")), "t sees its own buffered delete of k")

    # A CONCURRENT fresh begin() throughout sees v0 for k, None for k2 (the
    # uncommitted buffer is private to t).
    var other = ts.begin()
    _assert_some_eq(ts.get(other, _b("k")), "v0", "other sees committed v0")
    _assert_none(ts.get(other, _b("k2")), "other does NOT see t's buffered k2")

    ts.abort(t^)
    print("    [OK] (c)")


# =============================================================================
# (d) OCC write-write — deterministic variant (the discriminating signal).
#     DISCRIMINATING: a naive append-without-OCC commits BOTH (lost update).
# =============================================================================


def test_d_occ_write_write_deterministic() raises:
    print("[d] OCC write-write (deterministic) — DISCRIMINATING")
    var ts = _new_mem_store(String("pg/d"))
    var s0 = _commit_put(ts, String("k"), String("v0"))  # LSN 0
    assert_equal(s0, Int64(0), "v0 at LSN 0")

    # tA and tB both pin S0 = 0 and both write k.
    var tA = ts.begin()
    var tB = ts.begin()
    assert_equal(tA.snapshot_lsn, Int64(0), "tA pins S0")
    assert_equal(tB.snapshot_lsn, Int64(0), "tB pins S0")
    tA.update(_b("k"), _b("vA"))
    tB.update(_b("k"), _b("vB"))

    # commit(tA) wins slot S0+1 = 1.
    var rA = ts.commit(tA^)
    assert_equal(rA.commit_lsn, Int64(1), "tA wins slot 1")

    # commit(tB) MUST raise OCC_CONFLICT (40001): its OCC window (S0, 1]
    # contains tA's chunk which touched k in tB's write-set. A naive impl that
    # appends without the OCC check would commit tB at slot 2 (LOST UPDATE) and
    # this assertion would NOT see a raise.
    var got_conflict = False
    try:
        var rB = ts.commit(tB^)
        _ = rB
    except e:
        if is_occ_conflict(String(e)):
            got_conflict = True
        else:
            raise e^
    assert_true(
        got_conflict, "commit(tB) raised OCC_CONFLICT 40001 (first-comm-wins)"
    )

    # After abort, tB2 re-begins (pins S1=1), updates, commits at S0+2 = 2.
    var tB2 = ts.begin()
    assert_equal(tB2.snapshot_lsn, Int64(1), "tB2 pins S1")
    tB2.update(_b("k"), _b("vB"))
    var rB2 = ts.commit(tB2^)
    assert_equal(rB2.commit_lsn, Int64(2), "tB2 wins slot 2")

    # A fresh read sees vB (the eventually-committed value).
    var fresh = ts.begin()
    _assert_some_eq(ts.get(fresh, _b("k")), "vB", "final value = vB")

    # Disjoint-key txns at the same snapshot BOTH commit (OCC only conflicts on
    # overlapping keys).
    var s2 = ts.wal_head_seq()
    assert_equal(s2, Int64(2), "head at 2")
    var tX = ts.begin()
    var tY = ts.begin()
    tX.update(_b("x"), _b("xv"))
    tY.update(_b("y"), _b("yv"))
    var rX = ts.commit(tX^)  # wins slot 3
    var rY = ts.commit(tY^)  # disjoint key -> no conflict -> wins slot 4
    assert_equal(rX.commit_lsn, Int64(3), "tX wins slot 3 (disjoint)")
    assert_equal(rY.commit_lsn, Int64(4), "tY wins slot 4 (disjoint, no conf)")
    print("    [OK] (d) deterministic")


# =============================================================================
# (e) Durability / recovery — rebuild from WAL == committed state.
#     In-memory logic AND a real-filesystem TRUE crash-recovery variant.
# =============================================================================


def test_e_recovery_in_memory() raises:
    print("[e] durability / recovery (in-memory Arc-shared)")
    # Build a sequence: (k1,v1),(k2,v2),update(k1,v1'),delete(k2),(k3,v3)
    # LSNs 0..4 — over a SHARED store so the recovered TableStore reads the
    # same map after the original is dropped.
    from komira_objectstore.shared_in_memory_conditional_store import (
        SharedInMemoryConditionalStore,
    )

    var shared = SharedInMemoryConditionalStore()
    var prefix = String("pg/e/mem")

    # ---- scope 1: write the five txns, then DROP the TableStore ----
    var head_seq: Int64
    var orig = TableStore[SharedInMemoryConditionalStore].open(
        CasManifestStore[SharedInMemoryConditionalStore](
            store=shared.clone(), prefix=prefix.copy(),
            retry=RetryPolicy.fast_test(),
        )
    )
    var ta = orig.begin()
    ta.insert(_b("k1"), _b("v1"))
    _ = orig.commit(ta^)  # LSN 0
    var tb = orig.begin()
    tb.insert(_b("k2"), _b("v2"))
    _ = orig.commit(tb^)  # LSN 1
    var tc = orig.begin()
    tc.update(_b("k1"), _b("v1p"))
    _ = orig.commit(tc^)  # LSN 2
    var td = orig.begin()
    td.delete(_b("k2"))
    _ = orig.commit(td^)  # LSN 3
    var te = orig.begin()
    te.insert(_b("k3"), _b("v3"))
    var r4 = orig.commit(te^)  # LSN 4
    head_seq = r4.commit_lsn
    assert_equal(head_seq, Int64(4), "five txns -> LSN 4")
    _ = orig^  # DROP the in-RAM TableStore (its index is gone)

    # ---- scope 2: fresh TableStore.open over the SAME shared map (replay) ----
    var recovered = TableStore[SharedInMemoryConditionalStore].open(
        CasManifestStore[SharedInMemoryConditionalStore](
            store=shared.clone(), prefix=prefix.copy(),
            retry=RetryPolicy.fast_test(),
        )
    )
    # At a snapshot pinned at the new head (4):
    var head_reader = recovered.begin()
    assert_equal(head_reader.snapshot_lsn, Int64(4), "recovered head = 4")
    _assert_some_eq(
        recovered.get(head_reader, _b("k1")), "v1p", "recovered k1 = v1' (latest)"
    )
    _assert_none(
        recovered.get(head_reader, _b("k2")), "recovered k2 = None (tombstoned)"
    )
    _assert_some_eq(
        recovered.get(head_reader, _b("k3")), "v3", "recovered k3 = v3"
    )

    # Time-travel: a snapshot pinned at LSN 1 sees the EARLIER chain.
    var tt = Txn(Int64(1))
    _assert_some_eq(
        recovered.get(tt, _b("k1")), "v1", "time-travel k1@1 = v1"
    )
    _assert_some_eq(
        recovered.get(tt, _b("k2")), "v2", "time-travel k2@1 = v2"
    )
    print("    [OK] (e) in-memory")


def test_e_recovery_local_fs() raises:
    print("[e] durability / recovery (LocalFs — TRUE crash-recovery on disk)")
    var root = (_scratch_dir() + String("/table_store_test_e_")) + _unique()
    var prefix = String("pg/e/fs")

    # ---- scope 1: write, then DROP the TableStore (simulating a crash) ----
    var head_seq: Int64
    var orig = TableStore[LocalFsConditionalStore].open(
        CasManifestStore[LocalFsConditionalStore](
            store=LocalFsConditionalStore(root.copy()),
            prefix=prefix.copy(), retry=RetryPolicy.fast_test(),
        )
    )
    var t1 = orig.begin()
    t1.insert(_b("k1"), _b("v1"))
    _ = orig.commit(t1^)  # LSN 0
    var t2 = orig.begin()
    t2.insert(_b("k2"), _b("v2"))
    _ = orig.commit(t2^)  # LSN 1
    var t3 = orig.begin()
    t3.update(_b("k1"), _b("v1p"))
    _ = orig.commit(t3^)  # LSN 2
    var t4 = orig.begin()
    t4.delete(_b("k2"))
    _ = orig.commit(t4^)  # LSN 3
    var t5 = orig.begin()
    t5.insert(_b("k3"), _b("v3"))
    var r4 = orig.commit(t5^)  # LSN 4
    head_seq = r4.commit_lsn
    assert_equal(head_seq, Int64(4), "five txns on disk -> LSN 4")
    _ = orig^  # DROP — the bytes are on disk, the in-RAM index is gone.

    # ---- scope 2: fresh open over the SAME root dir -> LIST-recovery ----
    var recovered = TableStore[LocalFsConditionalStore].open(
        CasManifestStore[LocalFsConditionalStore](
            store=LocalFsConditionalStore(root.copy()),
            prefix=prefix.copy(), retry=RetryPolicy.fast_test(),
        )
    )
    var hr = recovered.begin()
    assert_equal(hr.snapshot_lsn, Int64(4), "recovered fs head = 4")
    _assert_some_eq(recovered.get(hr, _b("k1")), "v1p", "fs k1 = v1' (latest)")
    _assert_none(recovered.get(hr, _b("k2")), "fs k2 = None (tombstoned)")
    _assert_some_eq(recovered.get(hr, _b("k3")), "v3", "fs k3 = v3")
    # Time-travel still intact.
    var tt = Txn(Int64(1))
    _assert_some_eq(recovered.get(tt, _b("k1")), "v1", "fs time-travel k1@1=v1")
    _assert_some_eq(recovered.get(tt, _b("k2")), "v2", "fs time-travel k2@1=v2")
    print("    [OK] (e) local-fs")


# =============================================================================
# (f) Scan-at-snapshot — correct key set + per-key version, RYOW overlay.
# =============================================================================


def _scan_str(rows: List[KeyValue]) -> String:
    var out = String("[")
    for i in range(len(rows)):
        if i > 0:
            out += ","
        out += "(" + _str(rows[i].key) + "," + _str(rows[i].row) + ")"
    out += "]"
    return out^


def test_f_scan_at_snapshot() raises:
    print("[f] scan-at-snapshot (version + key set + RYOW)")
    var ts = _new_mem_store(String("pg/f"))
    # commit (a,1),(b,1),(c,1),(d,1) -> LSNs 0..3
    _ = _commit_put(ts, String("a"), String("1"))
    _ = _commit_put(ts, String("b"), String("1"))
    _ = _commit_put(ts, String("c"), String("1"))
    _ = _commit_put(ts, String("d"), String("1"))

    var reader = ts.begin()  # pins S = 3
    assert_equal(reader.snapshot_lsn, Int64(3), "reader pins S=3")

    # then commit update(b,2) LSN4, delete(c) LSN5, insert(e,1) LSN6.
    _ = _commit_put(ts, String("b"), String("2"))  # LSN 4
    _ = _commit_delete(ts, String("c"))  # LSN 5
    _ = _commit_put(ts, String("e"), String("1"))  # LSN 6

    # scan [a,z) at S=3 -> exactly [(a,1),(b,1),(c,1),(d,1)] (b at S<=3 version
    # 1 NOT 2; c present NOT tombstoned; e absent).
    var got = ts.scan(reader, _b("a"), _b("z"))
    assert_equal(len(got), 4, "scan@3 returns 4 rows: " + _scan_str(got))
    assert_true(bytes_eq(got[0].key, _b("a")) and bytes_eq(got[0].row, _b("1")), "f a@3=1")
    assert_true(bytes_eq(got[1].key, _b("b")) and bytes_eq(got[1].row, _b("1")), "f b@3=1 (not 2)")
    assert_true(bytes_eq(got[2].key, _b("c")) and bytes_eq(got[2].row, _b("1")), "f c@3 present")
    assert_true(bytes_eq(got[3].key, _b("d")) and bytes_eq(got[3].row, _b("1")), "f d@3=1")

    # A fresh begin() (pins S=6) scan returns [(a,1),(b,2),(d,1),(e,1)] —
    # b updated, c suppressed by tombstone, e present.
    var fresh = ts.begin()
    var got6 = ts.scan(fresh, _b("a"), _b("z"))
    assert_equal(len(got6), 4, "scan@6 returns 4 rows: " + _scan_str(got6))
    assert_true(bytes_eq(got6[0].key, _b("a")) and bytes_eq(got6[0].row, _b("1")), "f a@6=1")
    assert_true(bytes_eq(got6[1].key, _b("b")) and bytes_eq(got6[1].row, _b("2")), "f b@6=2")
    assert_true(bytes_eq(got6[2].key, _b("d")) and bytes_eq(got6[2].row, _b("1")), "f d@6=1 (c suppressed)")
    assert_true(bytes_eq(got6[3].key, _b("e")) and bytes_eq(got6[3].row, _b("1")), "f e@6=1")

    # Bounded scan [b,d) at S=3 -> [(b,1),(c,1)] (half-open, d excluded).
    var bd = ts.scan(reader, _b("b"), _b("d"))
    assert_equal(len(bd), 2, "scan[b,d)@3 returns 2: " + _scan_str(bd))
    assert_true(bytes_eq(bd[0].key, _b("b")), "f bounded b")
    assert_true(bytes_eq(bd[1].key, _b("c")), "f bounded c (d excluded)")

    # RYOW arm: inside an open txn that buffered update(a,99), the scan reflects
    # (a,99).
    var rw = ts.begin()
    rw.update(_b("a"), _b("99"))
    var ryow = ts.scan(rw, _b("a"), _b("z"))
    var found_a99 = False
    for i in range(len(ryow)):
        if bytes_eq(ryow[i].key, _b("a")):
            assert_true(bytes_eq(ryow[i].row, _b("99")), "f RYOW a=99")
            found_a99 = True
    assert_true(found_a99, "f RYOW scan reflects buffered a=99")
    ts.abort(rw^)
    print("    [OK] (f)")


# =============================================================================
# (g) HIGH-1 (adversarial review) — UNBOUNDED-UPPER scan (scan_from).
#     DISCRIMINATING against the old SQL-layer "64×0xFF max-key sentinel":
#     a key whose bytes sort AT/ABOVE that sentinel (>= 64 bytes of 0xFF) is
#     SILENTLY EXCLUDED by a half-open scan to that synthetic upper bound. The
#     fix moves +inf semantics into the storage layer: scan_from(lo) walks to
#     the END of the sorted key space, so NO real key is ever dropped, whatever
#     its length or byte content. This test injects such a high-byte key as a
#     raw List[UInt8] (a TEXT pk emits its raw bytes — encode_pk_text) and
#     proves scan_from includes it while a fixed 64×0xFF half-open `scan` drops
#     it (the RED-on-unfixed witness, asserted directly below).
# =============================================================================


def _hi_key(n: Int) -> List[UInt8]:
    """A key of `n` 0xFF bytes (sorts at/above any fixed-length 0xFF sentinel of
    length <= n)."""
    var out = List[UInt8]()
    for _ in range(n):
        out.append(UInt8(0xFF))
    return out^


def _max_key_64() -> List[UInt8]:
    """The OLD SQL-layer sentinel: 64 bytes of 0xFF. Reconstructed here ONLY to
    witness that the old half-open `scan([lo], <this>)` drops a >= 64×0xFF key
    (RED-on-unfixed) while the new scan_from does not."""
    return _hi_key(64)


def test_g_unbounded_upper_scan_high_byte_key() raises:
    print("[g] HIGH-1: scan_from includes a high-byte key the 64×0xFF sentinel drops")
    var ts = _new_mem_store(String("pg/g"))
    # Commit a spread of TEXT-pk-shaped keys, incl. an EMPTY key and a 70-byte
    # all-0xFF key that sorts AT/ABOVE the old 64×0xFF sentinel.
    var t = ts.begin()
    t.insert(List[UInt8](), _b("empty"))  # '' (empty key) — sorts first
    t.insert(_b("a"), _b("ra"))
    t.insert(_b("ab"), _b("rab"))
    t.insert(_b("b"), _b("rb"))
    t.insert(_b("z"), _b("rz"))
    t.insert(_hi_key(70), _b("rhi"))  # 70×0xFF — >= the 64×0xFF sentinel
    _ = ts.commit(t^)

    var reader = ts.begin()

    # scan_from([]) — the full UNBOUNDED-UPPER scan — must return ALL 6 keys in
    # byte-lexicographic order, with the high-byte key LAST and NONE dropped.
    var allk = ts.scan_from(reader, List[UInt8]())
    assert_equal(
        len(allk), 6, "scan_from([]) returns all 6 keys: " + _scan_str(allk)
    )
    assert_equal(len(allk[0].key), 0, "g[0] is the empty key (sorts first)")
    assert_true(bytes_eq(allk[1].key, _b("a")), "g[1]=a")
    assert_true(bytes_eq(allk[2].key, _b("ab")), "g[2]=ab")
    assert_true(bytes_eq(allk[3].key, _b("b")), "g[3]=b")
    assert_true(bytes_eq(allk[4].key, _b("z")), "g[4]=z")
    assert_true(bytes_eq(allk[5].key, _hi_key(70)), "g[5]=70×0xFF (high-byte, LAST)")
    assert_true(bytes_eq(allk[5].row, _b("rhi")), "g high-byte row present")

    # scan_from from "a" inclusive: includes everything >= "a", incl. the
    # high-byte key (drops only the empty key < "a").
    var fromA = ts.scan_from(reader, _b("a"))
    assert_equal(len(fromA), 5, "scan_from(a) returns 5: " + _scan_str(fromA))
    assert_true(
        bytes_eq(fromA[len(fromA) - 1].key, _hi_key(70)),
        "g scan_from(a) includes the high-byte key LAST",
    )

    # RED-ON-UNFIXED WITNESS: the OLD path was scan([lo], 64×0xFF) (half-open).
    # That synthetic upper bound EXCLUDES any key >= 64×0xFF — the 70-byte key is
    # silently dropped. We assert that the OLD bounded form drops it AND the NEW
    # scan_from keeps it, so the test is RED iff scan_from regresses to the
    # sentinel behavior.
    var old_bounded = ts.scan(reader, List[UInt8](), _max_key_64())
    var old_has_hi = False
    for i in range(len(old_bounded)):
        if bytes_eq(old_bounded[i].key, _hi_key(70)):
            old_has_hi = True
    assert_false(
        old_has_hi,
        "WITNESS: the 64×0xFF sentinel scan DROPS the high-byte key (the bug)",
    )
    var new_has_hi = False
    for i in range(len(allk)):
        if bytes_eq(allk[i].key, _hi_key(70)):
            new_has_hi = True
    assert_true(
        new_has_hi, "scan_from KEEPS the high-byte key (the fix)"
    )
    print("    [OK] (g) HIGH-1 unbounded-upper scan")


# =============================================================================
# (h) MUST-FIX #1 — cross-handle snapshot-isolation on a SHARED store.
#     DISCRIMINATING: the pre-fix "local hit wins / no scan WAL fallback" code
#     returns the handle's OWN stale version (stale read / resurrected
#     tombstone) and drops cross-handle keys from scan (phantom-absence). The
#     production shape this slice validates is MANY stateless workers, each a
#     TableStore over ONE shared prefix — a reader MUST observe other handles'
#     commits committed <= its snapshot.
# =============================================================================


def _open_shared(
    shared: SharedInMemoryConditionalStore, prefix: String
) raises -> TableStore[SharedInMemoryConditionalStore]:
    """A fresh TableStore HANDLE over a clone() of the shared store + prefix
    (each handle has its OWN partial in-RAM index; cross-handle visibility must
    go through the WAL)."""
    return TableStore[SharedInMemoryConditionalStore].open(
        CasManifestStore[SharedInMemoryConditionalStore](
            store=shared.clone(),
            prefix=prefix.copy(),
            retry=RetryPolicy.fast_test(),
        )
    )


def test_h_cross_handle_snapshot_isolation() raises:
    print(
        "[h] cross-handle SI on a shared store — DISCRIMINATING (MUST-FIX #1)"
    )
    var shared = SharedInMemoryConditionalStore()
    var prefix = String("pg/h")

    # Handle H commits PUT k=v1 (LSN 0) and PUT m=mv (LSN 1, a key only H ever
    # touches — proves scan picks up H's keys cross-handle for a G-reader too).
    var H = _open_shared(shared, prefix)
    var tk = H.begin()
    tk.insert(_b("k"), _b("v1"))
    var rk = H.commit(tk^)
    assert_equal(rk.commit_lsn, Int64(0), "H k=v1 at LSN 0")
    var tm = H.begin()
    tm.insert(_b("m"), _b("mv"))
    var rm = H.commit(tm^)
    assert_equal(rm.commit_lsn, Int64(1), "H m=mv at LSN 1")

    # A SEPARATE handle G (its own partial index) commits a NEWER PUT k=v2 at
    # LSN L, and a TOMBSTONE on a separate key `g_del` that it first creates
    # then deletes (so the tombstone is the newest version <= the reader's snap).
    var G = _open_shared(shared, prefix)
    var tg0 = G.begin()
    tg0.insert(_b("g_del"), _b("gv"))
    var rg0 = G.commit(tg0^)
    assert_equal(rg0.commit_lsn, Int64(2), "G g_del=gv at LSN 2")
    var tg1 = G.begin()
    tg1.update(_b("k"), _b("v2"))  # NEWER k version, committed by G
    var rg1 = G.commit(tg1^)
    var L = rg1.commit_lsn
    assert_equal(L, Int64(3), "G k=v2 at LSN 3")
    var tg2 = G.begin()
    tg2.delete(_b("g_del"))  # tombstone the key G created at LSN 2
    var rg2 = G.commit(tg2^)
    assert_equal(rg2.commit_lsn, Int64(4), "G TOMBSTONE g_del at LSN 4")

    # A reader on H with snapshot >= L (>= 4 here) MUST see:
    #   - k = v2 (G's newer cross-handle commit, NOT H's own stale v1)
    #   - g_del = None (G's cross-handle tombstone is the newest version <= snap)
    #   - m = mv (H's own key, still present)
    # and scan MUST include G's keys (k at v2; g_del suppressed).
    var reader = H.begin()  # pins the shared head (4)
    assert_true(
        reader.snapshot_lsn >= L,
        "H reader snapshot >= L (sees G's commit window)",
    )
    _assert_some_eq(
        H.get(reader, _b("k")), "v2",
        "DISCRIMINATING: H reader sees G's newer k=v2 (NOT stale local v1)",
    )
    _assert_none(
        H.get(reader, _b("g_del")),
        "DISCRIMINATING: H reader sees G's tombstone of g_del (None)",
    )
    _assert_some_eq(
        H.get(reader, _b("m")), "mv", "H reader still sees H's own m=mv"
    )

    # scan [a,z) at the reader's snapshot MUST include the cross-handle keys.
    var rows = H.scan(reader, _b("a"), _b("z"))
    # visible at snapshot 4: k=v2, m=mv (g_del tombstoned, suppressed).
    assert_equal(
        len(rows), 2, "scan includes cross-handle keys (k,m): " + _scan_str(rows)
    )
    assert_true(
        bytes_eq(rows[0].key, _b("k")) and bytes_eq(rows[0].row, _b("v2")),
        "DISCRIMINATING: scan k=v2 (cross-handle, not stale v1)",
    )
    assert_true(
        bytes_eq(rows[1].key, _b("m")) and bytes_eq(rows[1].row, _b("mv")),
        "scan m=mv (H's own key)",
    )

    # SI stability arm: a reader pinned at an EARLIER snapshot (S=0, before G's
    # commits) on H must STILL see H's k=v1 (NOT G's later v2), and g_del absent
    # (it did not exist at LSN 0). This is the SI guarantee — folding up to the
    # snapshot, never to the live head.
    var early = Txn(Int64(0))
    _assert_some_eq(
        H.get(early, _b("k")), "v1", "SI: early reader@0 sees k=v1 (not v2)"
    )
    _assert_none(
        H.get(early, _b("g_del")), "SI: early reader@0 — g_del did not exist"
    )
    _ = shared^
    print("    [OK] (h) cross-handle SI")


# =============================================================================
# (i) MUST-FIX #2 — §8 head-coupling: commit's OCC + slot claim MUST use the
#     AUTHORITATIVE head, not the cached _HEAD (which lags cross-handle). The
#     pre-fix lag window never opens single-process; this test forces the cached
#     _HEAD to LAG the authoritative tail and asserts an overlapping-write txn
#     still ABORTS 40001 (it must consult read_head_authoritative).
# =============================================================================


def test_i_commit_uses_authoritative_head() raises:
    print("[i] commit consults authoritative head — DISCRIMINATING (MUST-FIX #2)")
    var shared = SharedInMemoryConditionalStore()
    var prefix = String("pg/i")

    # Handle H1 seeds k=v0 (LSN 0). The shared _HEAD object now says chunk 0.
    var H1 = _open_shared(shared, prefix)
    var t0 = H1.begin()
    t0.insert(_b("k"), _b("v0"))
    var r0 = H1.commit(t0^)
    assert_equal(r0.commit_lsn, Int64(0), "seed k=v0 at LSN 0")

    # H1 pins a snapshot at S0 = 0 and buffers a conflicting write to k. It does
    # NOT commit yet.
    var tH = H1.begin()
    assert_equal(tH.snapshot_lsn, Int64(0), "H1 txn pins S0=0")
    tH.update(_b("k"), _b("vH"))

    # Force the cached _HEAD to LAG the authoritative tail. A conflicting chunk
    # k=v_other is written DIRECTLY at slot 1 (winning the create-CAS at the
    # chunk key) WITHOUT advancing the shared `_HEAD` object — then we REWIND
    # `_HEAD` to still say chunk_seq 0. This is the cross-process lag window the
    # §8 coupling guards: the cached `read_head()` returns 0 (stale) while
    # `read_head_authoritative()` LISTs the bucket and returns the true tail 1.
    # (Both local stores advance cached `_HEAD` synchronously in-process, so the
    # lag window never opens via the normal append path — we open it by hand.)
    var direct = shared.clone()
    var conflict_ws = List[WriteOp]()
    conflict_ws.append(WriteOp(PG_OP_PUT, _b("k"), _b("v_other")))
    var conflict_body = encode_commit_chunk(Int64(0), conflict_ws)
    # base_offset = 1 (slot 0 carried 1 record). encode_chunk wraps the body in
    # the store's chunk envelope with the record_count.
    var encoded = encode_chunk(conflict_body, Int64(1))
    var meta = direct.conditional_put(
        chunk_key(prefix.copy(), Int64(1)),
        encoded,
        WritePrecondition.if_none_match_star(),
    )
    _ = meta
    # REWIND the shared `_HEAD` object to chunk 0 (unconditional overwrite) so
    # the cached read genuinely lags the bucket's true tail (slot 1 exists).
    var stale_head = encode_head(ManifestHead(Int64(0), Int64(1), String("")))
    var hmeta = direct.conditional_put(
        head_key(prefix.copy()), stale_head, WritePrecondition.none()
    )
    _ = hmeta

    # Sanity: cached read_head LAGS (0) while authoritative LISTs the true tail
    # (1) — the lag window is genuinely open.
    var probe = CasManifestStore[SharedInMemoryConditionalStore](
        store=shared.clone(), prefix=prefix.copy(),
        retry=RetryPolicy.fast_test(),
    )
    assert_equal(
        probe.read_head().chunk_seq, Int64(0), "cached _HEAD lags at 0"
    )
    assert_equal(
        probe.read_head_authoritative().chunk_seq,
        Int64(1),
        "authoritative head sees the true tail 1",
    )
    _ = probe^

    # Now H1 commits tH (snapshot 0, writes k). Its OCC window is (0, head].
    # If commit consults the AUTHORITATIVE head, head = 1, the window (0, 1]
    # contains the cross-handle chunk which touched k in tH's write-set => ABORT
    # 40001. If commit (regressed) consulted the cached _HEAD (still 0), the
    # window would be empty (0, 0] and tH would WRONGLY commit (lost update).
    var got_conflict = False
    try:
        var rH = H1.commit(tH^)
        _ = rH
    except e:
        if is_occ_conflict(String(e)):
            got_conflict = True
        else:
            raise e^
    assert_true(
        got_conflict,
        "DISCRIMINATING: H1 commit ABORTS 40001 vs the cross-handle chunk in"
        " its lagged-cache window (consulted authoritative head, not _HEAD)",
    )
    _ = direct^
    _ = shared^
    print("    [OK] (i) commit uses authoritative head")


# =============================================================================
# (j) MUST-FIX #2(b) — try_append_at_seq is a SINGLE-SLOT CAS: a pre-occupied
#     candidate_seq returns None (412 / precondition) and NEVER escalates to a
#     higher slot. Contrast with plain append's cached-head escalation. This is
#     the primitive the §8 coupling relies on (the won slot is ALWAYS exactly
#     occ_validated_head + 1).
# =============================================================================


def test_j_try_append_at_seq_no_escalation() raises:
    print("[j] try_append_at_seq single-slot, no escalation (MUST-FIX #2b)")
    var shared = SharedInMemoryConditionalStore()
    var prefix = String("pg/j")

    var wal = CasManifestStore[SharedInMemoryConditionalStore](
        store=shared.clone(), prefix=prefix.copy(),
        retry=RetryPolicy.fast_test(),
    )

    # Occupy slot 0 with a real commit chunk.
    var ws0 = List[WriteOp]()
    ws0.append(WriteOp(PG_OP_PUT, _b("a"), _b("0")))
    var body0 = encode_commit_chunk(Int64(-1), ws0)
    var w0 = wal.try_append_at_seq(Int64(0), Int64(0), body0, Int64(1))
    assert_true(Bool(w0), "slot 0 won")
    assert_equal(w0.value().chunk_seq, Int64(0), "slot 0 chunk_seq == 0")

    # Re-attempt slot 0 (now occupied): MUST return None (412), NOT escalate to
    # slot 1. A plain append would re-read the cached head and escalate to the
    # next free slot — try_append_at_seq must NOT.
    var ws1 = List[WriteOp]()
    ws1.append(WriteOp(PG_OP_PUT, _b("b"), _b("1")))
    var body1 = encode_commit_chunk(Int64(-1), ws1)
    var w_again = wal.try_append_at_seq(Int64(0), Int64(0), body1, Int64(1))
    assert_false(
        Bool(w_again),
        "DISCRIMINATING: occupied slot 0 returns None (no escalation to 1)",
    )

    # Slot 1 must still be FREE (try_append_at_seq did not consume it). Prove it
    # by winning slot 1 explicitly.
    var auth = wal.read_head_authoritative()
    assert_equal(auth.chunk_seq, Int64(0), "authoritative head still 0")
    var w1 = wal.try_append_at_seq(
        auth.chunk_seq + Int64(1), auth.next_offset, body1, Int64(1)
    )
    assert_true(Bool(w1), "slot 1 still free -> won")
    assert_equal(w1.value().chunk_seq, Int64(1), "slot 1 chunk_seq == 1")
    _ = wal^
    _ = shared^
    print("    [OK] (j) try_append_at_seq no-escalation")


# =============================================================================
# DISCRIMINATING PROOF — the (b) + (d) properties stated as direct, naive-impl-
# falsifying assertions (documented evidence that they discriminate).
# =============================================================================


def test_discriminating_b_si_falsifies_read_latest() raises:
    # If the impl read the LATEST chain entry (naive read-latest), an
    # S0-pinned reader would observe a later commit. We assert it does NOT.
    print("[disc-b] SI falsifies read-latest")
    var ts = _new_mem_store(String("pg/disc_b"))
    _ = _commit_put(ts, String("k"), String("v0"))  # LSN 0
    var reader = ts.begin()  # S0 = 0
    _ = _commit_put(ts, String("k"), String("v1"))  # LSN 1 — newest is v1
    # read-latest WOULD return v1 here; SI returns v0.
    _assert_some_eq(
        ts.get(reader, _b("k")), "v0",
        "DISCRIMINATING: S0-reader must NOT see the newer v1",
    )
    print("    [OK] disc-b")


def test_discriminating_d_occ_falsifies_blind_append() raises:
    # If the impl appended without the OCC check (naive), commit(tB) would
    # SUCCEED (lost update) and the final value could be vB-over-vA with both
    # committed. We assert exactly ONE of the two same-key concurrent writers
    # commits and the other raises 40001.
    print("[disc-d] OCC falsifies blind-append (lost update)")
    var ts = _new_mem_store(String("pg/disc_d"))
    _ = _commit_put(ts, String("k"), String("v0"))  # LSN 0
    var tA = ts.begin()
    var tB = ts.begin()
    tA.update(_b("k"), _b("vA"))
    tB.update(_b("k"), _b("vB"))
    var rA = ts.commit(tA^)
    assert_true(rA.did_append, "disc-d: tA committed")

    var b_committed = False
    var b_conflicted = False
    try:
        var rB = ts.commit(tB^)
        b_committed = rB.did_append
    except e:
        if is_occ_conflict(String(e)):
            b_conflicted = True
        else:
            raise e^
    # DISCRIMINATING: a blind-append impl makes b_committed True (lost update).
    # The correct impl makes b_conflicted True and b_committed False.
    assert_false(b_committed, "DISCRIMINATING: tB must NOT blind-commit (no lost update)")
    assert_true(b_conflicted, "DISCRIMINATING: tB must raise OCC_CONFLICT 40001")
    print("    [OK] disc-d")


# =============================================================================
# (k) WAL format version — the magic's trailing digit IS a format version.
#     decode_commit_chunk parses it, reserves schema_version, and REJECTS an
#     unknown version (flag-day insurance, analytics convergence §6 items 1+2).
# =============================================================================


def test_k_format_version_roundtrip() raises:
    print("[k] format-version round-trip + reserved schema_version == 0")
    # A normal encode produces a format-version-2 body whose schema_version is
    # the reserved 0 (the storage layer never schematizes the row in this slice).
    var ws = List[WriteOp]()
    ws.append(WriteOp(PG_OP_PUT, _b("k1"), _b("r1")))
    ws.append(WriteOp(PG_OP_PUT, _b("k2"), _b("r2")))
    var body = encode_commit_chunk(Int64(7), ws)

    var chunk = decode_commit_chunk(body)
    assert_equal(chunk.snapshot_lsn, Int64(7), "snapshot_lsn survives round-trip")
    assert_equal(
        chunk.schema_version,
        PG_SCHEMA_VERSION_UNSET,
        "reserved schema_version reads back as 0",
    )
    assert_equal(len(chunk.write_set), 2, "both writes survive round-trip")
    assert_true(bytes_eq(chunk.write_set[0].key, _b("k1")), "k1 key intact")
    assert_true(bytes_eq(chunk.write_set[0].row, _b("r1")), "r1 row intact")
    assert_true(bytes_eq(chunk.write_set[1].key, _b("k2")), "k2 key intact")
    assert_true(bytes_eq(chunk.write_set[1].row, _b("r2")), "r2 row intact")

    # The keys-only fast path decodes the SAME header layout (offsets shifted by
    # the schema_version slot) — it must also see both keys.
    var keys = decode_commit_chunk_keys(body)
    assert_equal(len(keys), 2, "keys-only decode sees both keys")
    assert_true(bytes_eq(keys[0], _b("k1")), "keys-only k1")
    assert_true(bytes_eq(keys[1], _b("k2")), "keys-only k2")
    print("    [OK] (k) round-trip")


def _decode_raises(body: List[UInt8]) -> Bool:
    """True iff decode_commit_chunk REJECTS `body` (raises)."""
    try:
        var c = decode_commit_chunk(body)
        _ = c^
        return False
    except e:
        _ = e
        return True


def _decode_keys_raises(body: List[UInt8]) -> Bool:
    """True iff decode_commit_chunk_keys REJECTS `body` (raises)."""
    try:
        var ks = decode_commit_chunk_keys(body)
        _ = ks^
        return False
    except e:
        _ = e
        return True


def test_k_reject_unknown_format_version() raises:
    print("[k] DISCRIMINATING — decode REJECTS an unknown format version")
    var ws = List[WriteOp]()
    ws.append(WriteOp(PG_OP_PUT, _b("k1"), _b("r1")))
    var good = encode_commit_chunk(Int64(0), ws)
    # Baseline: the well-formed body decodes cleanly (no false-positive reject).
    assert_false(_decode_raises(good), "well-formed v2 body decodes OK")

    # --- Bumped version digit ("PGC9") — the DISCRIMINATING case. -------------
    # Keep the "PGC" lineage prefix intact; only flip the trailing version byte
    # (offset 3, the magic's high byte) to ASCII '9'. This is the case a
    # version-check-REMOVED build would happily MISPARSE (the prefix is valid,
    # the rest of the body is a perfectly-formed v2 layout) — so it is the test
    # that goes RED if CHANGE 1's `version != PG_COMMIT_FORMAT_VERSION` reject is
    # deleted. We assert it RAISES.
    var bumped = good.copy()
    bumped[3] = UInt8(0x39)  # ASCII '9' -> format version 9, which we do not know
    assert_true(
        _decode_raises(bumped),
        "DISCRIMINATING: an unknown format version (PGC9) is REJECTED, not"
        " silently misparsed",
    )
    # The keys-only fast path must reject it too (same validation routing).
    assert_true(
        _decode_keys_raises(bumped),
        "keys-only decode also REJECTS the unknown version",
    )

    # --- Garbage version byte (non-digit) — also rejected. -------------------
    var garbage = good.copy()
    garbage[3] = UInt8(0xFF)  # not an ASCII digit at all
    assert_true(
        _decode_raises(garbage), "non-digit version byte is REJECTED"
    )

    # --- Corrupt the "PGC" lineage prefix — rejected on the prefix guard. ----
    var bad_prefix = good.copy()
    bad_prefix[0] = UInt8(0x00)  # 'P' -> NUL: no longer the PGC lineage
    assert_true(
        _decode_raises(bad_prefix), "corrupt lineage prefix is REJECTED"
    )

    # Sanity on the constant the reject compares against (guards an accidental
    # version bump that forgets to update the layout/tests).
    assert_equal(
        Int(PG_COMMIT_FORMAT_VERSION),
        2,
        "current WAL commit-chunk format version is 2",
    )
    print("    [OK] (k) reject-unknown-version is discriminating")


# =============================================================================
# unique suffix for the LocalFs root (avoid cross-run collisions)
# =============================================================================


def _unique() -> String:
    from std.time import perf_counter_ns

    var x = UInt64(perf_counter_ns())
    x ^= x >> UInt64(33)
    x *= UInt64(0xFF51AFD7ED558CCD)
    x ^= x >> UInt64(33)
    var out = String("")
    var shift = 60
    while shift >= 0:
        var nib = Int((x >> UInt64(shift)) & UInt64(0xF))
        if nib < 10:
            out += chr(0x30 + nib)
        else:
            out += chr(0x61 + nib - 10)
        shift -= 4
    return out^


def main() raises:
    print("== table store correctness slice (deterministic) ==")
    test_a_commit_atomicity()
    test_b_snapshot_isolation()
    test_c_read_your_own_writes()
    test_d_occ_write_write_deterministic()
    test_e_recovery_in_memory()
    test_e_recovery_local_fs()
    test_f_scan_at_snapshot()
    test_g_unbounded_upper_scan_high_byte_key()  # HIGH-1
    test_h_cross_handle_snapshot_isolation()
    test_i_commit_uses_authoritative_head()
    test_j_try_append_at_seq_no_escalation()
    test_discriminating_b_si_falsifies_read_latest()
    test_discriminating_d_occ_falsifies_blind_append()
    test_k_format_version_roundtrip()
    test_k_reject_unknown_format_version()
    print(
        "[OK] test_table_store_correctness — (a) atomicity, (b) SI, (c) RYOW,"
        " (d) OCC-deterministic, (e) recovery (mem+fs), (f) scan,"
        " (h) cross-handle SI, (i) auth-head coupling, (j) single-slot CAS,"
        " (k) WAL format version reject — all green"
    )
