# =============================================================================
# tests/komira_pgstore/test_pgstore_list_delimiter_audit.mojo
#   C-LIST-DELIMITER (PRIORITY 1) — the highest-leverage production-bug guard.
# =============================================================================
#
# THE BUG CLASS (recurring; hit 3x in the broker rollout — team-lead memory
# "Real-S3 LIST-delimiter trap"): object-store sub-dir enumeration that folds
# ONLY `listed.objects` (never `listed.common_prefixes`) returns EMPTY on real
# S3/GCS — but PASSES on the in-memory store, which IGNORES the delimiter and
# dumps every key under the prefix into `objects` (`common_prefixes` always
# empty). A nested-prefix enumeration that folds objects-only therefore silently
# regresses to EMPTY on production while every offline test stays green.
#
# WHAT THIS TEST PROVES (the audit, made a test):
#   1. THE S-5 STORE IS DELIMITER-FAITHFUL. A unit assertion that the new
#      `DelimiterFaithfulConditionalStore` puts FLAT keys (no '/' after the
#      prefix) in `objects` and NESTED keys (a '/' after the prefix) ONLY in
#      `common_prefixes` — and that the SAME keyset on the plain
#      `InMemoryConditionalStore` collapses to objects-only (the trap baseline).
#      This makes the store itself a discriminating instrument, not a black box.
#
#   2. THE pgstore COMMIT + RECOVERY PATH IS NOT VULNERABLE. Commit a NON-EMPTY
#      history on one handle, then drive a COLD `TableStore.open` recovery on a
#      FRESH handle over a CLONE of the SAME backing store (bucket-is-truth) and
#      assert the recovered head == the true tail AND every committed row reads
#      back. The recovery's only input is the faithful-listing bucket
#      (`_recover_head_by_list` -> `_list_chunks`). The pgstore WAL chunk keys
#      are FLAT leaf files directly under `<prefix>/manifest/`
#      (`<prefix>/manifest/<seq:020d>.chunk`), so the objects-only fold is SOUND
#      over a faithful store — this is the NON-VACUOUS proof of that (count > 0;
#      recovered tail == committed tail). If any commit/recovery enumeration on
#      the pgstore path EVER folded a NESTED prefix objects-only, recovery would
#      miss chunks here -> RED.
#
#   3. THE TRAP IS REAL FOR NESTED PREFIXES. A direct demonstration that an
#      objects-only fold of a NESTED prefix (`_meta/dedup/<pid>/<seq>.seq` shape,
#      the pgstore/broker sentinel layout) returns EMPTY on the faithful store
#      while the correct `objects ∪ seq-bearing(common_prefixes)` fold finds the
#      rollups — so a future enumeration that adopts that shape WITHOUT folding
#      common_prefixes would be caught here (INV-10 enumeration completeness).
#
# AUDIT FINDING (documented for the COO; the source is NOT changed here):
#   Every enumeration in the pgstore commit + recovery path
#   (`table_store.mojo` -> `CasManifestStore.read_head_authoritative` ->
#   `_recover_head_by_list` -> `_list_chunks`) lists the FLAT `<prefix>/manifest/`
#   prefix and folds `res.objects`. Because the chunk keys are leaf files (no '/'
#   after the prefix), objects-only is the CORRECT fold for that prefix — the
#   pgstore recovery path is NOT vulnerable to the LIST-delimiter trap. The
#   NESTED enumerations in `cas_manifest.mojo` (the reaper's `_meta/dedup/` LIST,
#   tombstones) are NOT on the pgstore commit/recovery path (pgstore never
#   produces dedup sentinels). This test pins that finding so a future refactor
#   that moves a pgstore enumeration onto a nested prefix without folding
#   common_prefixes is caught.
#
# Encapsulation / stale-reuse: ZERO UnsafePointer in any signature; ZERO wildcard
# origins / unsafe_from_address / take_pointee. The store is a plain owned
# value; the recovery drives through the typed TableStore surface.
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false

from komira_objectstore.cas_manifest import (
    CasManifestStore,
    RetryPolicy,
)
from komira_objectstore.delimiter_faithful_conditional_store import (
    DelimiterFaithfulConditionalStore,
)
from komira_objectstore.in_memory_conditional_store import (
    InMemoryConditionalStore,
)
from komira_objectstore.path import Path
from komira_objectstore.store import ConditionalWriteStore
from komira_objectstore.types import WritePrecondition

from komira_pgstore.pgstore_codec import bytes_eq
from komira_pgstore.table_store import TableStore, Txn


# =============================================================================
# byte helpers
# =============================================================================


def _b(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    var sb = s.as_bytes()
    for i in range(len(sb)):
        out.append(sb[i])
    return out^


# =============================================================================
# (1) THE S-5 STORE IS DELIMITER-FAITHFUL — and the in-mem twin is the trap.
# =============================================================================


def test_s5_store_is_delimiter_faithful() raises:
    """The new store splits a LIST into `objects` (flat leaves) vs
    `common_prefixes` (sub-dir rollups) — the real S3/GCS semantic — while the
    plain in-memory store collapses everything to `objects` (the trap baseline).
    """
    print("[c-list-delimiter] (1) S-5 DelimiterFaithfulConditionalStore split")

    # Put a mix: 2 FLAT leaves directly under `root/`, and 3 NESTED keys under
    # `root/sub/...` (two distinct sub-dirs).
    var df = DelimiterFaithfulConditionalStore()
    _ = df.put(Path.parse("root/flatA.txt"), _b("a"))
    _ = df.put(Path.parse("root/flatB.txt"), _b("b"))
    _ = df.put(Path.parse("root/sub1/deep1.txt"), _b("c"))
    _ = df.put(Path.parse("root/sub1/deep2.txt"), _b("d"))
    _ = df.put(Path.parse("root/sub2/deep3.txt"), _b("e"))

    var res = df.list_with_delimiter(Path.parse("root/"))

    # FAITHFUL: exactly the 2 flat leaves in `objects`; the 3 nested keys are
    # hidden behind their 2 deduped sub-dir rollups in `common_prefixes`.
    assert_equal(
        len(res.objects), 2,
        "faithful list: exactly the 2 FLAT leaves are `objects`",
    )
    var saw_flatA = False
    var saw_flatB = False
    for i in range(len(res.objects)):
        var loc = res.objects[i].location
        if loc == String("root/flatA.txt"):
            saw_flatA = True
        if loc == String("root/flatB.txt"):
            saw_flatB = True
        # CRITICAL: a NESTED key must NEVER appear in `objects`.
        assert_false(
            loc == String("root/sub1/deep1.txt")
            or loc == String("root/sub1/deep2.txt")
            or loc == String("root/sub2/deep3.txt"),
            "a NESTED key must NOT appear in `objects` (it is hidden behind its"
            " common-prefix rollup): " + loc,
        )
    assert_true(saw_flatA and saw_flatB, "both flat leaves present in objects")

    # The 2 sub-dirs appear DEDUPED in common_prefixes (deep1 + deep2 collapse
    # to one `root/sub1/` rollup).
    assert_equal(
        len(res.common_prefixes), 2,
        "faithful list: exactly 2 DEDUPED sub-dir rollups in common_prefixes",
    )
    var saw_sub1 = False
    var saw_sub2 = False
    for i in range(len(res.common_prefixes)):
        if res.common_prefixes[i] == String("root/sub1/"):
            saw_sub1 = True
        if res.common_prefixes[i] == String("root/sub2/"):
            saw_sub2 = True
    assert_true(saw_sub1 and saw_sub2, "both sub-dir rollups present")

    # THE TRAP BASELINE: the SAME keyset on the plain in-memory store ignores the
    # delimiter -> ALL 5 keys in `objects`, `common_prefixes` empty. An
    # objects-only fold over THIS store would (wrongly) "see" the nested keys,
    # masking the bug.
    var mem = InMemoryConditionalStore()
    _ = mem.put(Path.parse("root/flatA.txt"), _b("a"))
    _ = mem.put(Path.parse("root/flatB.txt"), _b("b"))
    _ = mem.put(Path.parse("root/sub1/deep1.txt"), _b("c"))
    _ = mem.put(Path.parse("root/sub1/deep2.txt"), _b("d"))
    _ = mem.put(Path.parse("root/sub2/deep3.txt"), _b("e"))
    var memres = mem.list_with_delimiter(Path.parse("root/"))
    assert_equal(
        len(memres.objects), 5,
        "in-mem twin IGNORES the delimiter: all 5 keys land in `objects`"
        " (the trap baseline — masks an objects-only nested-fold bug)",
    )
    assert_equal(
        len(memres.common_prefixes), 0,
        "in-mem twin never populates common_prefixes",
    )
    _ = df^
    _ = mem^
    print("    [OK] (1) S-5 store faithful; in-mem twin is the trap baseline")


# =============================================================================
# (2) THE pgstore COMMIT + RECOVERY PATH IS SOUND over a FAITHFUL store.
#     (NON-VACUOUS: a non-empty set of committed chunks; recovered head == tail.)
# =============================================================================


def _new_ts(
    shared: DelimiterFaithfulConditionalStore, prefix: String
) raises -> TableStore[DelimiterFaithfulConditionalStore]:
    return TableStore[DelimiterFaithfulConditionalStore].open(
        CasManifestStore[DelimiterFaithfulConditionalStore](
            store=shared.clone(),
            prefix=prefix.copy(),
            retry=RetryPolicy.fast_test(),
        )
    )


def test_pgstore_recovery_over_faithful_store_nonvacuous() raises:
    """Drive a REAL cold TableStore recovery over the delimiter-faithful store
    with a NON-EMPTY committed history and assert the recovered head == the true
    tail + every row reads back. The recovery's ONLY input is the faithful
    bucket (a FRESH handle over a clone of the same backing store — no _HEAD in
    the fresh handle's index, so `open()` LIST-recovers via `_list_chunks`). If
    any commit/recovery enumeration on the pgstore path folded a NESTED prefix
    objects-only, recovery would MISS chunks here -> RED. Today it is GREEN
    because the pgstore WAL chunk keys are FLAT leaves under `<prefix>/manifest/`
    (objects-only is the correct fold for that flat prefix)."""
    print(
        "[c-list-delimiter] (2) pgstore cold recovery over the FAITHFUL store"
        " (non-vacuous)"
    )
    var shared = DelimiterFaithfulConditionalStore()
    var prefix = String("pg/listdelim/recover")

    # ---- COMMIT a known, NON-EMPTY history (8 chunks: 4 keys overwritten +
    #      a final tombstone) on the WRITER handle. ----
    var n_commits = 8
    var writer = _new_ts(shared, prefix)
    for i in range(n_commits):
        var t = writer.begin()
        if i == n_commits - 1:
            # last commit tombstones k0 (so the recovered view must hide it).
            t.delete(_b("k0"))
        else:
            var k = _b(String("k") + String(i % 4))  # 4 keys, overwritten
            t.insert(k.copy(), _b(String("v") + String(i)))
        var res = writer.commit(t^)
        assert_equal(
            res.commit_lsn, Int64(i),
            "commit LSN must be gapless: commit " + String(i),
        )
    var true_head = writer.wal_head_seq()
    assert_equal(
        true_head, Int64(n_commits - 1),
        "true authoritative head == n_commits-1 (non-vacuous: count > 0)",
    )
    _ = writer^

    # ---- COLD RECOVERY on a FRESH handle over a CLONE of the SAME backing
    #      store. `open()` LIST-recovers the authoritative head + replays the WAL
    #      — the ONLY input is the bucket (faithful listing). ----
    var recovered = _new_ts(shared, prefix)
    var rec_head = recovered.wal_head_seq()
    assert_equal(
        rec_head, true_head,
        "COLD recovery via LIST must find the TRUE tail (head="
        + String(Int(true_head)) + "); an objects-only nested fold would return"
        " a stale/empty head",
    )

    # The recovered MVCC view must match the committed history at the head:
    #   k0 tombstoned (last commit, i=7) -> invisible.
    #   k1 last written at i=5 (5%4==1) -> "v5".
    #   k2 last written at i=6 (6%4==2) -> "v6".
    #   k3 last written at i=3 (3%4==3) -> "v3".
    var rdr = recovered.begin()
    var k0 = recovered.get(rdr, _b("k0"))
    assert_false(Bool(k0), "k0 was tombstoned by the last commit -> invisible")
    var k1 = recovered.get(rdr, _b("k1"))
    assert_true(Bool(k1) and bytes_eq(k1.value(), _b("v5")), "k1 == v5")
    var k2 = recovered.get(rdr, _b("k2"))
    assert_true(Bool(k2) and bytes_eq(k2.value(), _b("v6")), "k2 == v6")
    var k3 = recovered.get(rdr, _b("k3"))
    assert_true(Bool(k3) and bytes_eq(k3.value(), _b("v3")), "k3 == v3")
    recovered.abort(rdr^)
    _ = recovered^
    _ = shared^
    print(
        "    [OK] (2) cold recovery via LIST found the true tail (head=",
        Int(true_head), ") + every row correct — pgstore recovery is NOT"
        " vulnerable to the LIST-delimiter trap",
    )


# =============================================================================
# (3) THE TRAP IS REAL FOR NESTED PREFIXES — direct demonstration.
# =============================================================================


def test_nested_prefix_objects_only_fold_is_empty() raises:
    """A direct demonstration of WHY common_prefixes must be folded for a NESTED
    enumeration. Put keys in the pgstore/broker sentinel shape
    (`_meta/dedup/<pid>/<seq>.seq`) and show that an objects-only fold of the
    nested `_meta/dedup/` prefix returns EMPTY on the faithful store, while the
    correct `objects ∪ seq-bearing(common_prefixes)` fold finds the rollups.
    (This is the falsifier any future pgstore enumeration over a NESTED prefix
    would have to pass — INV-10 enumeration completeness.)
    """
    print(
        "[c-list-delimiter] (3) nested-prefix objects-only fold returns EMPTY"
        " (the trap)"
    )
    var df = DelimiterFaithfulConditionalStore()
    # Two producers, two batches each — the nested sentinel layout.
    _ = df.put(
        Path.parse(
            "p/_meta/dedup/00000000000000000001/00000000000000000000.seq"
        ),
        _b("x"),
    )
    _ = df.put(
        Path.parse(
            "p/_meta/dedup/00000000000000000001/00000000000000000005.seq"
        ),
        _b("y"),
    )
    _ = df.put(
        Path.parse(
            "p/_meta/dedup/00000000000000000002/00000000000000000000.seq"
        ),
        _b("z"),
    )

    var res = df.list_with_delimiter(Path.parse("p/_meta/dedup/"))

    # THE TRAP: objects-only over the NESTED prefix is EMPTY (every key is one
    # level deeper -> all in common_prefixes).
    assert_equal(
        len(res.objects), 0,
        "objects-only fold of a NESTED prefix is EMPTY on a faithful store"
        " (THIS is the LIST-delimiter trap — an enumeration that stops here"
        " silently loses every nested key on real S3/GCS)",
    )
    # THE CORRECT FOLD: common_prefixes carries the 2 deduped producer rollups.
    assert_equal(
        len(res.common_prefixes), 2,
        "the CORRECT fold reads common_prefixes: 2 deduped producer rollups",
    )
    var saw_p1 = False
    var saw_p2 = False
    for i in range(len(res.common_prefixes)):
        if res.common_prefixes[i] == String(
            "p/_meta/dedup/00000000000000000001/"
        ):
            saw_p1 = True
        if res.common_prefixes[i] == String(
            "p/_meta/dedup/00000000000000000002/"
        ):
            saw_p2 = True
    assert_true(saw_p1 and saw_p2, "both producer rollups in common_prefixes")
    _ = df^
    print(
        "    [OK] (3) demonstrated: objects-only nested fold is EMPTY; the fix"
        " is to fold objects ∪ common_prefixes (INV-10 enumeration completeness)"
    )


def main() raises:
    print("== pgstore LIST-delimiter audit (C-LIST-DELIMITER, PRIORITY 1) ==")
    test_s5_store_is_delimiter_faithful()
    test_pgstore_recovery_over_faithful_store_nonvacuous()
    test_nested_prefix_objects_only_fold_is_empty()
    print(
        "[OK] test_pgstore_list_delimiter_audit — the S-5 faithful store is a"
        " discriminating instrument; the pgstore commit/recovery path folds"
        " objects-only over the FLAT manifest prefix (SOUND, proven"
        " non-vacuously); the nested-prefix trap is demonstrated so a future"
        " nested enumeration without common_prefixes is caught (INV-10)"
    )
