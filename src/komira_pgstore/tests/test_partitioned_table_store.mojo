# =============================================================================
# tests/komira_pgstore/test_partitioned_table_store.mojo
#   WS-2 — PartitionedTableStore router + per-shard commit (RELAXED §10 scope).
#   (heap Model-2 sharding campaign).
# =============================================================================
#
# Design: the heap key-space partition design
#   §1.5 (router shell, wrap-not-edit) + §5 (single-shard fast path) +
#   §10 (the relaxed-semantics build target) + §10.3 (what WS-2 drops).
#
# The DISCRIMINATING falsifiers for the shard-aware router, asserted against the
# REAL TableStore OCC substrate over a SharedInMemoryConditionalStore (Arc-shared
# map, so all N shard sub-lineages reach the SAME logical bucket).
#
#   (1) single-shard route+commit — a write routes to its shard, commits via that
#       shard's unchanged TableStore.commit, and reads back correctly.
#   (2) NONE-table byte-identical — a NONE (K=1) router yields the SAME committed
#       state + the SAME create-CAS COUNT (one PUT-per-commit) as a plain
#       TableStore (the zero-overhead-at-1 proof).
#   (3) k>=2 routing + concat read — distinct keys route to distinct shards; a
#       cross-shard scan returns the UNION (concat, unordered) of all rows, no
#       loss / no dup.
#   (4) per-shard SI/MVCC preserved — OCC/snapshot/40001 holds WITHIN each shard
#       (the per-shard TableStore.commit is unchanged); a same-shard conflict
#       aborts 40001.
#   (5) cross-shard write v1 behavior — a DML whose keys span >1 shard is
#       REJECTED with the discriminable CROSS_SHARD_TXN_UNSUPPORTED_V1 token
#       (WS-3 deferral), NEVER a silent partial apply.
#   (6) RANGE routing — covering-shard pruning + single-shard ordered scan.
#   (7) disjoint-shard ISOLATION (the headline §5 win) — two txns with
#       OVERLAPPING snapshots on DIFFERENT shards BOTH commit, NO false
#       conflict (independent per-shard `_HEAD` slots; would 40001 if the
#       shards had collapsed onto one lineage).
#
# `medium` (LocalFs-free; SharedInMemory single-process, real-thread test (4) is
# deterministic single-thread OCC via two overlapping txns on one shard).
# =============================================================================

from std.testing import assert_equal, assert_false, assert_true

from komira_objectstore.shared_in_memory_conditional_store import (
    SharedInMemoryConditionalStore,
)
from komira_objectstore.cas_manifest import CasManifestStore, RetryPolicy

from komira_pgstore.key_index import KeyValue
from komira_pgstore.pgstore_codec import bytes_eq, WriteOp, PG_OP_PUT
from komira_pgstore.table_store import (
    TableStore,
    Txn,
    is_occ_conflict,
)
from komira_pgstore.partitioned_table_store import (
    PartitionedTableStore,
    PartitionSpec,
    hash_shard_to_id,
    is_cross_shard_unsupported,
    PART_SPEC_NONE,
    PART_SPEC_HASH,
    PART_SPEC_RANGE,
)


# =============================================================================
# Helpers
# =============================================================================


def _b(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    var sb = s.as_bytes()
    for i in range(len(sb)):
        out.append(sb[i])
    return out^


def _str(b: List[UInt8]) -> String:
    var out = String("")
    for i in range(len(b)):
        out += chr(Int(b[i]))
    return out


def _assert_some_eq(
    got: Optional[List[UInt8]], want: String, msg: String
) raises:
    assert_true(Bool(got), msg + " (expected Some, got None)")
    assert_true(bytes_eq(got.value(), _b(want)), msg + " (byte mismatch)")


def _assert_none(got: Optional[List[UInt8]], msg: String) raises:
    assert_false(Bool(got), msg + " (expected None / invisible)")


def _open_partitioned(
    var store: SharedInMemoryConditionalStore,
    part: String,
    var spec: PartitionSpec,
) raises -> PartitionedTableStore[SharedInMemoryConditionalStore]:
    return PartitionedTableStore[SharedInMemoryConditionalStore].open(
        store^, part, spec^
    )


def _commit_put_routed(
    mut ps: PartitionedTableStore[SharedInMemoryConditionalStore],
    k: String,
    v: String,
) raises -> Int64:
    """Begin on the key's shard, insert, commit (single-shard fast path)."""
    var t = ps.begin_for_key(_b(k))
    t.insert(_b(k), _b(v))
    var r = ps.commit(t^)
    return r.commit_lsn


def _row_value(rows: List[KeyValue], k: String) raises -> Optional[List[UInt8]]:
    for i in range(len(rows)):
        if bytes_eq(rows[i].key, _b(k)):
            return Optional(rows[i].row.copy())
    return Optional[List[UInt8]](None)


# =============================================================================
# (0) The routing primitive — deterministic + spreading (a unit pin).
# =============================================================================


def test_0_hash_shard_to_id_deterministic_and_spreads() raises:
    print("[0] hash_shard_to_id: deterministic + spreads a monotone hotspot")
    # Deterministic: same key -> same shard, twice.
    var a = hash_shard_to_id(_b("user-12345"), 4)
    var b = hash_shard_to_id(_b("user-12345"), 4)
    assert_equal(a, b, "hash routing is deterministic for the same key")
    assert_true(a >= 0 and a < 4, "hash routes into [0, k)")

    # k<=1 collapses to shard 0 (a 1-shard HASH table is a single lineage).
    assert_equal(
        hash_shard_to_id(_b("anything"), 1), 0, "k=1 -> shard 0"
    )
    assert_equal(
        hash_shard_to_id(_b("anything"), 0), 0, "k=0 -> shard 0 (degenerate)"
    )

    # Spreads a MONOTONE hotspot across all K shards (the reason HASH exists —
    # RANGE would pin the whole max(id)++ tail to one shard). Insert 200 dense
    # monotone keys; assert every one of K=4 shards receives some.
    var seen = List[Int]()
    for _ in range(4):
        seen.append(0)
    for i in range(200):
        var key = _b("id-" + String(1000000 + i))
        var s = hash_shard_to_id(key, 4)
        seen[s] += 1
    for s in range(4):
        assert_true(
            seen[s] > 0,
            "HASH spreads the monotone hotspot to shard "
            + String(s)
            + " (got 0 — a monotone key NOT spreading is the bug HASH fixes)",
        )


# =============================================================================
# (1) single-shard route + commit — write, route, commit-on-shard, read back.
# =============================================================================


def test_1_single_shard_route_commit_readback() raises:
    print("[1] single-shard route + commit + read-back")
    var ps = _open_partitioned(
        SharedInMemoryConditionalStore(),
        String("pg/ws2/single"),
        PartitionSpec.hash(4),
    )
    assert_true(ps.is_partitioned(), "K=4 HASH is partitioned")
    assert_equal(ps.shard_count(), 4, "4 declared shard slots")

    # Insert three keys; each routes to its own shard, commits via that shard's
    # unchanged TableStore.commit (one create-CAS).
    _ = _commit_put_routed(ps, String("alice"), String("a1"))
    _ = _commit_put_routed(ps, String("bob"), String("b1"))
    _ = _commit_put_routed(ps, String("carol"), String("c1"))

    # Read each back via the point-lookup prune (route -> one shard -> get).
    var ta = ps.begin_for_key(_b("alice"))
    _assert_some_eq(ps.get(ta, _b("alice")), String("a1"), "alice reads back")
    var tb = ps.begin_for_key(_b("bob"))
    _assert_some_eq(ps.get(tb, _b("bob")), String("b1"), "bob reads back")
    var tc = ps.begin_for_key(_b("carol"))
    _assert_some_eq(ps.get(tc, _b("carol")), String("c1"), "carol reads back")

    # An absent key is None (route to its shard, miss).
    var tz = ps.begin_for_key(_b("zzz"))
    _assert_none(ps.get(tz, _b("zzz")), "absent key -> None")
    _ = ps^


# =============================================================================
# (2) NONE-table byte-identical — a NONE (K=1) router == a plain TableStore in
#     committed state AND create-CAS COUNT (the zero-overhead-at-1 proof).
# =============================================================================


def test_2_none_table_byte_identical_to_plain() raises:
    print("[2] NONE-table byte-identical to a plain TableStore")
    # The same commit sequence applied to (a) a plain TableStore and (b) a NONE
    # (K=1) PartitionedTableStore over SEPARATE shared stores. Assert: identical
    # committed values, identical commit_lsn sequence, and identical create-CAS
    # PUT count (one PUT per commit in BOTH — the op-shape proof).

    # ---- (a) plain TableStore ----
    var plain_store = SharedInMemoryConditionalStore()
    var plain = TableStore[SharedInMemoryConditionalStore].open(
        CasManifestStore[SharedInMemoryConditionalStore](
            store=plain_store.clone(),
            prefix=String("pg/ws2/none/plain"),
            retry=RetryPolicy.fast_test(),
        )
    )
    plain_store.reset_op_counts()
    var p_lsns = List[Int64]()
    var seq = List[String]()
    seq.append(String("k1=v1"))
    seq.append(String("k2=v2"))
    seq.append(String("k1=v1p"))  # update
    var t1 = plain.begin()
    t1.insert(_b("k1"), _b("v1"))
    p_lsns.append(plain.commit(t1^).commit_lsn)
    var t2 = plain.begin()
    t2.insert(_b("k2"), _b("v2"))
    p_lsns.append(plain.commit(t2^).commit_lsn)
    var t3 = plain.begin()
    t3.update(_b("k1"), _b("v1p"))
    p_lsns.append(plain.commit(t3^).commit_lsn)
    var plain_puts = plain_store.n_put()
    # Read back.
    var pr = plain.begin()
    _assert_some_eq(plain.get(pr, _b("k1")), String("v1p"), "plain k1")
    _assert_some_eq(plain.get(pr, _b("k2")), String("v2"), "plain k2")

    # ---- (b) NONE (K=1) router ----
    var none_store = SharedInMemoryConditionalStore()
    var none = _open_partitioned(
        none_store.clone(),
        String("pg/ws2/none/router"),
        PartitionSpec.none(),
    )
    assert_false(none.is_partitioned(), "NONE spec is NOT partitioned")
    assert_equal(none.shard_count(), 1, "NONE router has exactly 1 shard")
    none_store.reset_op_counts()
    var n_lsns = List[Int64]()
    var nt1 = none.begin_on(0)
    nt1.insert(_b("k1"), _b("v1"))
    n_lsns.append(none.commit(nt1^).commit_lsn)
    var nt2 = none.begin_on(0)
    nt2.insert(_b("k2"), _b("v2"))
    n_lsns.append(none.commit(nt2^).commit_lsn)
    var nt3 = none.begin_on(0)
    nt3.update(_b("k1"), _b("v1p"))
    n_lsns.append(none.commit(nt3^).commit_lsn)
    var none_puts = none_store.n_put()
    var nr = none.begin_on(0)
    _assert_some_eq(none.get(nr, _b("k1")), String("v1p"), "none k1")
    _assert_some_eq(none.get(nr, _b("k2")), String("v2"), "none k2")

    # ---- the byte-identical assertions ----
    assert_equal(len(p_lsns), len(n_lsns), "same number of commits")
    for i in range(len(p_lsns)):
        assert_equal(
            p_lsns[i],
            n_lsns[i],
            "commit_lsn["
            + String(i)
            + "] identical (NONE router == plain: 0,1,2)",
        )
    # The op-shape proof: one create-CAS PUT per commit in BOTH (a NONE table
    # pays NO scatter / NO extra commit logic — zero-overhead-at-1).
    assert_equal(
        none_puts,
        plain_puts,
        "NONE router create-CAS PUT count == plain TableStore PUT count"
        " (zero-overhead-at-1: one PUT per commit, no router tax)",
    )
    _ = plain^
    _ = none^


# =============================================================================
# (3) k>=2 routing + concat read — distinct keys -> distinct shards; cross-shard
#     scan returns the union (concat, unordered), no loss / no dup.
# =============================================================================


def test_3_kshard_routing_and_concat_scan() raises:
    print("[3] k>=2 routing + cross-shard concat scan (union, no loss/dup)")
    var ps = _open_partitioned(
        SharedInMemoryConditionalStore(),
        String("pg/ws2/k4"),
        PartitionSpec.hash(4),
    )

    # Insert a spread of keys. Track which shard each routes to so we can ASSERT
    # the data genuinely landed on >1 distinct shard (else this is not a real
    # cross-shard test — it would pass even on a 1-shard store).
    var keys = List[String]()
    for i in range(12):
        keys.append(String("row-") + String(i))
    var distinct_shards = List[Int]()
    for i in range(len(keys)):
        var slot = ps.route(_b(keys[i]))
        var present = False
        for j in range(len(distinct_shards)):
            if distinct_shards[j] == slot:
                present = True
        if not present:
            distinct_shards.append(slot)
        _ = _commit_put_routed(ps, keys[i], String("val-") + String(i))
    assert_true(
        len(distinct_shards) >= 2,
        "the 12 keys genuinely span >= 2 shards (got "
        + String(len(distinct_shards))
        + ") — a real cross-shard scan",
    )

    # Cross-shard UNORDERED scan over [.. , ..) (unbounded) returns the UNION of
    # every shard's rows, concat order. Assert: exactly the 12 rows, each with
    # its own value, NO loss / NO dup.
    var rows = ps.scan_all_from_concat(_b(""))
    assert_equal(
        len(rows), 12, "cross-shard concat returns ALL 12 rows (no loss)"
    )
    # Each key appears EXACTLY once with its own value (no dup — a disjoint heap
    # partition has no cross-shard duplicates, so NO LWW dedup needed).
    for i in range(len(keys)):
        var got = _row_value(rows, keys[i])
        _assert_some_eq(
            got, String("val-") + String(i), "concat has " + keys[i]
        )
    # No-dup count check: total rows == distinct keys.
    var seen = List[String]()
    for i in range(len(rows)):
        var kk = _str(rows[i].key)
        for j in range(len(seen)):
            assert_true(
                seen[j] != kk,
                "key " + kk + " appears at most once (no dup across shards)",
            )
        seen.append(kk)
    assert_equal(len(seen), 12, "exactly 12 distinct keys in the union")
    _ = ps^


# =============================================================================
# (4) per-shard SI/MVCC preserved — OCC/snapshot/40001 holds WITHIN each shard.
# =============================================================================


def test_4_per_shard_occ_conflict_aborts() raises:
    print("[4] per-shard SI/MVCC: a SAME-SHARD write-write conflict aborts 40001")
    # Force two keys onto the SAME shard by using a RANGE spec whose single
    # boundary puts a known pair together, then run two overlapping txns that
    # both write the SAME key on that shard -> the loser must get 40001 from the
    # shard's UNCHANGED TableStore.commit (per-shard OCC is preserved verbatim).
    var ps = _open_partitioned(
        SharedInMemoryConditionalStore(),
        String("pg/ws2/occ"),
        PartitionSpec.hash(4),
    )
    var key = String("contended")
    var slot = ps.route(_b(key))

    # Seed the key so both txns pin a snapshot that SEES it.
    _ = _commit_put_routed(ps, key, String("seed"))

    # Two overlapping txns on the SAME shard, both updating the SAME key.
    var tA = ps.begin_on(slot)
    var tB = ps.begin_on(slot)
    tA.update(_b(key), _b("from-A"))
    tB.update(_b(key), _b("from-B"))

    # A commits first -> wins its shard's next create-CAS slot.
    var rA = ps.commit(tA^)
    assert_true(rA.commit_lsn >= Int64(0), "A commits on its shard")

    # B's overlapping update of the SAME key on the SAME shard -> 40001.
    var conflicted = False
    try:
        _ = ps.commit(tB^)
    except e:
        assert_true(
            is_occ_conflict(String(e)),
            "B's same-shard write-write conflict is a 40001 (per-shard OCC"
            " preserved): " + String(e),
        )
        conflicted = True
    assert_true(
        conflicted, "B MUST abort 40001 (the shard's unchanged OCC arbiter)"
    )

    # The committed value is A's (the winner), readable at a fresh snapshot.
    var rd = ps.begin_on(slot)
    _assert_some_eq(
        ps.get(rd, _b(key)), String("from-A"), "winner A's value is durable"
    )
    _ = ps^


# =============================================================================
# (5) cross-shard write v1 behavior — a DML spanning >1 shard is REJECTED with
#     the discriminable token, NEVER partial-applied (the safe choice, §10.2 G1).
# =============================================================================


def test_5_cross_shard_write_rejected_not_partial() raises:
    print("[5] cross-shard DML REJECTED (WS-3 deferral), not partial-applied")
    var ps = _open_partitioned(
        SharedInMemoryConditionalStore(),
        String("pg/ws2/xshard"),
        PartitionSpec.hash(4),
    )
    # Find two keys that route to DISTINCT shards (so one txn buffering both is a
    # genuine cross-shard DML).
    var ka = String("")
    var kb = String("")
    var sa = -1
    for i in range(64):
        var cand = String("xs-") + String(i)
        var s = ps.route(_b(cand))
        if sa < 0:
            ka = cand
            sa = s
        elif s != sa:
            kb = cand
            break
    assert_true(
        kb.byte_length() > 0, "found two keys routing to distinct shards (test setup)"
    )

    # One txn buffering BOTH keys -> the keys span >1 shard -> commit REJECTS.
    var t = ps.begin_for_key(_b(ka))
    t.insert(_b(ka), _b("va"))
    t.insert(_b(kb), _b("vb"))
    var rejected = False
    try:
        _ = ps.commit(t^)
    except e:
        assert_true(
            is_cross_shard_unsupported(String(e)),
            "cross-shard DML rejected with the WS-3 token: " + String(e),
        )
        rejected = True
    assert_true(
        rejected,
        "a >1-shard DML MUST be rejected loudly (WS-3), never partial-applied",
    )

    # NO partial corruption: NEITHER key is committed (the rejection happened
    # BEFORE any create-CAS — single-shard collapse check runs first).
    var ra = ps.begin_for_key(_b(ka))
    _assert_none(
        ps.get(ra, _b(ka)),
        "key A NOT committed (no partial apply on shard " + String(sa) + ")",
    )
    var rb = ps.begin_for_key(_b(kb))
    _assert_none(
        ps.get(rb, _b(kb)), "key B NOT committed (no partial apply)"
    )
    _ = ps^


# =============================================================================
# (6) RANGE routing — covering-shard pruning + ordered single-shard scan.
# =============================================================================


def test_6_range_routing_and_covering_prune() raises:
    print("[6] RANGE routing: covering-shard prune + single-shard order")
    # 3 shards split at "m" and "t": shard0 (-inf,"m"), shard1 ["m","t"),
    # shard2 ["t",+inf). A point key routes to its covering shard; route_range
    # prunes to the covering band.
    var bounds = List[List[UInt8]]()
    bounds.append(_b("m"))
    bounds.append(_b("t"))
    var ps = _open_partitioned(
        SharedInMemoryConditionalStore(),
        String("pg/ws2/range"),
        PartitionSpec.range(bounds^),
    )
    assert_equal(ps.shard_count(), 3, "2 boundaries -> 3 shards")

    # Point routing.
    assert_equal(ps.route(_b("apple")), 0, "'apple' < 'm' -> shard 0")
    assert_equal(ps.route(_b("mango")), 1, "'m' <= 'mango' < 't' -> shard 1")
    assert_equal(ps.route(_b("zebra")), 2, "'zebra' >= 't' -> shard 2")

    # route_range covering prune: ["a","n") covers shards {0,1}, not shard 2.
    # Both bounds present -> has_lo / has_hi True (no unbounded-side saturation).
    var cover = ps.route_range(_b("a"), _b("n"), True, True)
    assert_equal(len(cover), 2, "['a','n') covers exactly 2 adjacent shards")
    assert_equal(cover[0], 0, "covering band starts at shard 0")
    assert_equal(cover[1], 1, "covering band ends at shard 1 (prunes shard 2)")

    # WS-4 unbounded-side SATURATION (the route_range has_lo/has_hi fix): an
    # unbounded UPPER (`pk >= "n"`, has_hi=False) must cover `[route("n") ..
    # last]` = shards {1, 2}, NOT collapse to `[1 .. route(empty)=0]` (empty).
    var cover_hi = ps.route_range(_b("n"), List[UInt8](), True, False)
    assert_equal(len(cover_hi), 2, "unbounded-upper covers shards 1+2")
    assert_equal(cover_hi[0], 1, "unbounded-upper band starts at shard 1")
    assert_equal(cover_hi[1], 2, "unbounded-upper band reaches the LAST shard")
    # An unbounded LOWER (`pk < "n"`, has_lo=False) covers `[0 .. route("n")]` =
    # shards {0, 1}.
    var cover_lo = ps.route_range(List[UInt8](), _b("n"), False, True)
    assert_equal(len(cover_lo), 2, "unbounded-lower covers shards 0+1")
    assert_equal(cover_lo[0], 0, "unbounded-lower band starts at shard 0")
    assert_equal(cover_lo[1], 1, "unbounded-lower band ends at shard 1")

    # Commit keys across all three shards; a covering scan of ["a","n") returns
    # ONLY shard 0+1 rows (the prune is real — shard 2's 'zebra' is excluded).
    _ = _commit_put_routed(ps, String("apple"), String("A"))
    _ = _commit_put_routed(ps, String("mango"), String("M"))
    _ = _commit_put_routed(ps, String("zebra"), String("Z"))
    var rows = ps.scan_all_concat(_b("a"), _b("n"))
    assert_equal(len(rows), 2, "covering scan returns only shards 0+1 rows")
    _assert_some_eq(_row_value(rows, String("apple")), String("A"), "apple in")
    _assert_some_eq(_row_value(rows, String("mango")), String("M"), "mango in")
    _assert_none(
        _row_value(rows, String("zebra")),
        "zebra PRUNED out of the ['a','n') covering scan",
    )
    _ = ps^


# =============================================================================
# (7) disjoint-shard ISOLATION — two txns with OVERLAPPING snapshots on
#     DIFFERENT shards BOTH commit, NO false conflict (the headline §5 win).
# =============================================================================


def test_7_disjoint_shard_overlapping_txns_both_commit() raises:
    print("[7] disjoint-shard isolation: overlapping txns on diff shards commit")
    # THE HEADLINE PARTITIONING WIN (review LOW-1, made discriminating). On a
    # SINGLE-lineage TableStore, two concurrent txns that each write share ONE
    # `_HEAD` create-CAS slot — the second to commit would OCC-conflict 40001 on
    # the contended head even if the keys are unrelated (the contention test (4)
    # asserts that conflict IS preserved WITHIN a shard). The whole point of
    # heap partitioning is that two txns whose keys route to DIFFERENT shards hit
    # INDEPENDENT `_HEAD` slots — so they BOTH commit with NO false conflict.
    #
    # This is the falsifier for "did we actually get per-shard isolation, or did
    # everything collapse onto one lineage": run two txns with TRULY OVERLAPPING
    # lifetimes (both begun, then both committed) on two distinct shards, and
    # assert NEITHER raises (no 40001) and BOTH values are durable.
    var ps = _open_partitioned(
        SharedInMemoryConditionalStore(),
        String("pg/ws2/disjoint"),
        PartitionSpec.hash(4),
    )

    # Find two keys that route to DISTINCT shards (else this is not a disjoint
    # test — they'd share one lineage and one would legitimately conflict).
    var ka = String("")
    var kb = String("")
    var sa = -1
    var sb = -1
    for i in range(64):
        var cand = String("dj-") + String(i)
        var s = ps.route(_b(cand))
        if sa < 0:
            ka = cand
            sa = s
        elif s != sa:
            kb = cand
            sb = s
            break
    assert_true(
        kb.byte_length() > 0 and sa != sb,
        "found two keys routing to DISTINCT shards (test setup)",
    )

    # OVERLAPPING lifetimes: begin BOTH txns (each on its own shard) BEFORE
    # either commits — so their snapshots are concurrent, the exact shape that
    # would false-conflict on a single shared lineage.
    var tA = ps.begin_for_key(_b(ka))
    var tB = ps.begin_for_key(_b(kb))
    tA.insert(_b(ka), _b("from-A"))
    tB.insert(_b(kb), _b("from-B"))

    # BOTH commit — NO false conflict (independent per-shard `_HEAD` slots). If
    # the router had collapsed onto one lineage, one of these would 40001.
    var conflicted = False
    try:
        var rA = ps.commit(tA^)
        assert_true(rA.commit_lsn >= Int64(0), "A commits on shard " + String(sa))
        var rB = ps.commit(tB^)
        assert_true(rB.commit_lsn >= Int64(0), "B commits on shard " + String(sb))
    except e:
        conflicted = is_occ_conflict(String(e))
        assert_true(
            False,
            "disjoint-shard txns MUST NOT false-conflict (got: "
            + String(e)
            + "); a 40001 here means the shards collapsed onto one lineage",
        )
    assert_false(
        conflicted,
        "neither disjoint-shard txn raised 40001 (per-shard isolation holds)",
    )

    # Both values are durable, each on its own shard (read back via the prune).
    var ra = ps.begin_for_key(_b(ka))
    _assert_some_eq(ps.get(ra, _b(ka)), String("from-A"), "A durable on its shard")
    var rb = ps.begin_for_key(_b(kb))
    _assert_some_eq(ps.get(rb, _b(kb)), String("from-B"), "B durable on its shard")
    _ = ps^


def main() raises:
    test_0_hash_shard_to_id_deterministic_and_spreads()
    test_1_single_shard_route_commit_readback()
    test_2_none_table_byte_identical_to_plain()
    test_3_kshard_routing_and_concat_scan()
    test_4_per_shard_occ_conflict_aborts()
    test_5_cross_shard_write_rejected_not_partial()
    test_6_range_routing_and_covering_prune()
    test_7_disjoint_shard_overlapping_txns_both_commit()
    print("\nALL WS-2 PartitionedTableStore tests passed.")
