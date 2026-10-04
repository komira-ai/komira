# =============================================================================
# tests/komira_pgstore/test_pgstore_secondary_index.mojo
#   SI slice 1 — the STORAGE-LEVEL discriminating falsifiers for the per-index
#   memtable family in TableStore (register_index + routed fold + index_scan_
#   visible). These probe the index MEMTABLE directly, so a stub that does NOT
#   build / route / version the index memtable FAILS — unlike a SQL-face test
#   whose result a full-scan fallback could reproduce.
# =============================================================================
#
# The SQL-face test (tests/komira_pgsql/test_secondary_index.mojo) proves the
# end-to-end `WHERE col = ?` correctness, but a full-scan fallback yields the
# SAME rows, so those asserts do not DISCRIMINATE "index consulted". This file
# closes that gap: it asserts directly on `TableStore.index_scan_visible`, which
# reads ONLY the routed index memtable — there is no full-scan path that could
# produce these results. Each test below FAILS on a stub that:
#   * does not register / route into a per-index memtable (index_scan empty), or
#   * does not give the index its OWN MVCC chain (inline-tombstone visibility), or
#   * does not replay index WriteOps into the index memtable on reopen, or
#   * does not fold cross-handle index commits (stale index scan).
#
# Design: the secondary-index design §2/§4/§5/§8.
# =============================================================================

from std.testing import assert_equal, assert_false, assert_true

from komira_objectstore.cas_manifest import CasManifestStore, RetryPolicy
from komira_objectstore.in_memory_conditional_store import (
    InMemoryConditionalStore,
)
from komira_objectstore.local_fs_conditional_store import (
    LocalFsConditionalStore,
)
from komira_objectstore.shared_in_memory_conditional_store import (
    SharedInMemoryConditionalStore,
)
from komira_objectstore.store import ConditionalWriteStore

from komira_pgstore.key_index import KeyValue
from komira_pgstore.table_store import TableStore, Txn
from komira_runtime_paths import test_tmpdir


def _scratch_dir() raises -> String:
    """The directory THIS execution may write scratch files into.

    `test_tmpdir()` is $TEST_TMPDIR, private to this run; it raises rather than
    falling back to a `/tmp` path that concurrent runs would share.
    """
    return test_tmpdir()


# =============================================================================
# Helpers — build storage-level keys WITHOUT the pgsql codec (keep this test on
# the pgstore leaf only). An index lineage ordinal lives in the disjoint high
# band; a heap key in the low band. We hand-encode the 4-byte big-endian ordinal
# prefix that `TableStore._key_lineage_ord` reads.
# =============================================================================

# The disjoint high-band base mirrors row_image_codec.INDEX_LINEAGE_BAND_BASE
# (2^30) — but this test stays on the pgstore leaf, so we hard-code the band.
comptime _IDX_BAND: Int32 = 0x40000000
comptime _HEAP_TID: Int32 = 0  # the heap table ordinal (low band)


def _ord_prefix(ordinal: Int32) -> List[UInt8]:
    """The 4-byte BIG-ENDIAN lineage-ordinal prefix (matches
    row_image_codec.encode_table_prefix / TableStore._key_lineage_ord)."""
    var u = UInt32(Int(ordinal))
    var out = List[UInt8]()
    for i in range(4):
        var shift = UInt32(8 * (3 - i))
        out.append(UInt8((u >> shift) & UInt32(0xFF)))
    return out^


def _heap_key(pk: UInt8) -> List[UInt8]:
    """A heap key: low-band table prefix ++ a 1-byte pk."""
    var out = _ord_prefix(_HEAP_TID)
    out.append(pk)
    return out^


def _idx_key(lineage: Int32, seg: UInt8, pk: UInt8) -> List[UInt8]:
    """An index entry key: high-band lineage prefix ++ [seg byte][pk byte]
    (a single fixed-width composite segment + pk tiebreak, storage-level)."""
    var out = _ord_prefix(lineage)
    out.append(seg)
    out.append(pk)
    return out^


def _b(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    var sb = s.as_bytes()
    for i in range(len(sb)):
        out.append(sb[i])
    return out^


def _new_mem_store(prefix: String) raises -> TableStore[InMemoryConditionalStore]:
    var wal = CasManifestStore[InMemoryConditionalStore](
        store=InMemoryConditionalStore(),
        prefix=prefix,
        retry=RetryPolicy.fast_test(),
    )
    return TableStore[InMemoryConditionalStore].open(wal^)


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
        out += chr(0x30 + nib) if nib < 10 else chr(0x61 + nib - 10)
        shift -= 4
    return out^


def _idx_pks_at[
    Store: ConditionalWriteStore
](
    mut store: TableStore[Store], txn: Txn, lineage: Int32
) raises -> List[UInt8]:
    """Scan the WHOLE index lineage at the txn snapshot, returning the visible
    entries' pk bytes (the LAST byte of each composite key). Reads ONLY the index
    memtable via `index_scan_visible` (NO heap full-scan path exists for this)."""
    var lo = _ord_prefix(lineage)
    var hi = _ord_prefix(lineage + Int32(1))
    var entries = store.index_scan_visible(txn, lineage, lo^, hi^)
    var out = List[UInt8]()
    for i in range(len(entries)):
        ref k = entries[i].key
        out.append(k[len(k) - 1])  # the pk byte (the final composite-key byte)
    return out^


def _pkset_str(pks: List[UInt8]) -> String:
    var out = String("[")
    for i in range(len(pks)):
        if i > 0:
            out += ","
        out += String(Int(pks[i]))
    out += "]"
    return out^


# =============================================================================
# (0s) routing — register_index + a single-chunk heap+index commit splits the
#      keyspaces: index_scan_visible sees the index entry, the heap get sees the
#      heap row. FAILS on a stub with no per-index memtable (index_scan empty).
# =============================================================================


def test_0s_routing_splits_keyspaces() raises:
    print("[0s] register_index + routed single-chunk commit splits keyspaces")
    var store = _new_mem_store(String("sis/0_") + _unique())
    var lineage = _IDX_BAND
    store.register_index(lineage)

    # ONE write-set: a heap PUT + an index PUT (invariant #1 single-commit-LSN).
    var t = store.begin()
    t.insert(_heap_key(1), _b("row1"))
    t.insert(_idx_key(lineage, 30, 1), List[UInt8]())  # index entry (seg=30,pk=1)
    var r = store.commit(t^)
    assert_equal(r.commit_lsn, Int64(0), "single chunk at LSN 0")

    var rd = store.begin()
    # the index memtable holds the entry (routed by the high-band prefix).
    var pks = _idx_pks_at(store, rd, lineage)
    assert_equal(_pkset_str(pks), String("[1]"), "index entry routed -> pk {1}")
    # the heap memtable holds the heap row.
    var hk = store.get(rd, _heap_key(1))
    assert_true(Bool(hk), "heap row present")
    print("    [OK] (0s)")


# =============================================================================
# (ii-s) inline-tombstone visibility on the INDEX'S OWN chain (the §4 core).
#        FAILS on a stub that does not version the index entries.
# =============================================================================


def test_iis_inline_tombstone_visibility() raises:
    print("[ii-s] inline-tombstone visibility resolves on the index's own chain")
    var store = _new_mem_store(String("sis/ii_") + _unique())
    var lineage = _IDX_BAND
    store.register_index(lineage)

    # c0: PUT index entry (seg=5, pk=1) + heap row.
    var t0 = store.begin()
    t0.insert(_heap_key(1), _b("v5"))
    t0.insert(_idx_key(lineage, 5, 1), List[UInt8]())
    var c0 = store.commit(t0^).commit_lsn

    # c1: indexed-col UPDATE 5->7 => TOMBSTONE (5,1) + PUT (7,1) (one chunk).
    var t1 = store.begin()
    t1.insert(_heap_key(1), _b("v7"))
    t1.delete(_idx_key(lineage, 5, 1))  # tombstone the OLD index entry
    t1.insert(_idx_key(lineage, 7, 1), List[UInt8]())  # the NEW index entry
    var c1 = store.commit(t1^).commit_lsn
    assert_true(c1 > c0, "update commits above the insert")

    # a reader pinned at c0 sees the OLD entry (5,1) live: scanning the (5)
    # sub-range returns pk 1.
    var r0 = store.begin()
    # pin r0 at c0 explicitly (it may pin the live head; reads fold <= snapshot).
    r0.snapshot_lsn = c0
    var seg5_at_c0 = _seg_pks(store, r0, lineage, 5)
    assert_equal(_pkset_str(seg5_at_c0), String("[1]"), "S=c0 seg=5 -> {1}")

    # a reader at c1 sees the (5,1) entry TOMBSTONED (gone) and (7,1) live.
    var r1 = store.begin()
    r1.snapshot_lsn = c1
    var seg5_at_c1 = _seg_pks(store, r1, lineage, 5)
    assert_equal(len(seg5_at_c1), 0, "S=c1 seg=5 -> {} (old entry tombstoned)")
    var seg7_at_c1 = _seg_pks(store, r1, lineage, 7)
    assert_equal(_pkset_str(seg7_at_c1), String("[1]"), "S=c1 seg=7 -> {1}")
    print("    [OK] (ii-s)")


def _seg_pks[
    Store: ConditionalWriteStore
](
    mut store: TableStore[Store], txn: Txn, lineage: Int32, seg: UInt8
) raises -> List[UInt8]:
    """Scan the index sub-range for one segment value `seg` (composite keys
    `[lineage][seg][pk]`): lo = prefix++[seg], hi = prefix++[seg+1]. Returns the
    visible pk bytes. A true point-range over the index memtable."""
    var lo = _ord_prefix(lineage)
    lo.append(seg)
    var hi = _ord_prefix(lineage)
    hi.append(seg + UInt8(1))
    var entries = store.index_scan_visible(txn, lineage, lo^, hi^)
    var out = List[UInt8]()
    for i in range(len(entries)):
        ref k = entries[i].key
        out.append(k[len(k) - 1])
    return out^


# =============================================================================
# (iv-s) recovery — reopen + register_index rebuilds the index memtable from the
#        WAL (the catch-up fold). FAILS on a stub that does not replay/route.
# =============================================================================


def test_ivs_recovery_rebuilds_index() raises:
    print("[iv-s] reopen + register_index rebuilds the index memtable from WAL")
    var dir = (_scratch_dir() + String("/sis_iv_")) + _unique()
    var prefix = String("siswal")
    var lineage = _IDX_BAND

    var s1 = TableStore[LocalFsConditionalStore].open(
        CasManifestStore[LocalFsConditionalStore](
            store=LocalFsConditionalStore(dir),
            prefix=prefix, retry=RetryPolicy.fast_test(),
        )
    )
    s1.register_index(lineage)
    var t = s1.begin()
    t.insert(_heap_key(1), _b("a"))
    t.insert(_idx_key(lineage, 30, 1), List[UInt8]())
    t.insert(_heap_key(3), _b("c"))
    t.insert(_idx_key(lineage, 30, 3), List[UInt8]())
    _ = s1.commit(t^)
    _ = s1^  # DROP — index memtable gone; bytes on disk.

    # reopen: open() replays into the HEAP (lineage not yet registered), then
    # register_index does the catch-up fold over the already-folded WAL range.
    var s2 = TableStore[LocalFsConditionalStore].open(
        CasManifestStore[LocalFsConditionalStore](
            store=LocalFsConditionalStore(dir),
            prefix=prefix, retry=RetryPolicy.fast_test(),
        )
    )
    s2.register_index(lineage)  # catch-up fold rebuilds the index memtable
    var rd = s2.begin()
    var pks = _seg_pks(s2, rd, lineage, 30)
    assert_equal(
        _pkset_str(pks), String("[1,3]"),
        "reopened index seg=30 -> {1,3} (catch-up fold from WAL)",
    )
    print("    [OK] (iv-s)")


# =============================================================================
# (vii-s) cross-handle — handle B sees A's committed index entry after the
#         cross-handle fold refreshes B's INDEX memtable. FAILS on a stub that
#         refreshes only the heap memtable.
# =============================================================================


def test_viis_cross_handle_index_refresh() raises:
    print("[vii-s] cross-handle index memtable refresh")
    var prefix = String("sis/vii_") + _unique()
    var shared = SharedInMemoryConditionalStore()
    var lineage = _IDX_BAND

    var sA = TableStore[SharedInMemoryConditionalStore].open(
        CasManifestStore[SharedInMemoryConditionalStore](
            store=shared.clone(), prefix=prefix.copy(),
            retry=RetryPolicy.fast_test(),
        )
    )
    sA.register_index(lineage)
    var sB = TableStore[SharedInMemoryConditionalStore].open(
        CasManifestStore[SharedInMemoryConditionalStore](
            store=shared.clone(), prefix=prefix.copy(),
            retry=RetryPolicy.fast_test(),
        )
    )
    sB.register_index(lineage)

    # B reads the lineage BEFORE A commits -> empty.
    var b0 = sB.begin()
    var before = _seg_pks(sB, b0, lineage, 30)
    assert_equal(len(before), 0, "B pre-A-commit seg=30 -> empty")

    # A commits a heap+index entry (seg=30, pk=7).
    var ta = sA.begin()
    ta.insert(_heap_key(7), _b("z"))
    ta.insert(_idx_key(lineage, 30, 7), List[UInt8]())
    _ = sA.commit(ta^)

    # B (its index memtable STALE) reads -> MUST see A's entry after the cross-
    # handle fold refreshes B's INDEX memtable (not just the heap).
    var b1 = sB.begin()
    var after = _seg_pks(sB, b1, lineage, 30)
    assert_equal(
        _pkset_str(after), String("[7]"),
        "B sees A's cross-handle index commit (index memtable refreshed)",
    )
    print("    [OK] (vii-s)")


def main() raises:
    test_0s_routing_splits_keyspaces()
    test_iis_inline_tombstone_visibility()
    test_ivs_recovery_rebuilds_index()
    test_viis_cross_handle_index_refresh()
    print("[secondary-index slice 1 — STORAGE] all discriminating probes GREEN")
