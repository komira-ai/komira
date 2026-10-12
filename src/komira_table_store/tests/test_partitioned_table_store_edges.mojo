# =============================================================================
# src/komira_table_store/tests/test_partitioned_table_store_edges.mojo
#   The partitioned router's edges: degenerate shard counts, the HASH/NONE
#   covering set, the begin-shard == commit-shard refusal, a read-only commit,
#   the reopen-with-smaller-K refusal, and the shard-id ordinal parser.
# =============================================================================
#
# What each test proves:
#   * hash_shard_to_id maps every key to shard 0 when k is 1, 0 or negative
#     (no modulo by zero or by a negative count).
#   * a spec with k = 0 still opens one shard (the whole keyspace).
#   * route_range covers every shard for HASH and the one shard for NONE.
#   * a txn begun on shard 0 whose write routes to shard 1 is refused with the
#     cross-shard token and nothing is written; a read-only txn begun on shard
#     0 commits as read-only.
#   * reopening a table whose shard p3 holds committed rows with k = 3 is
#     refused, naming p3 and the K it needs; reopening with k = 4 works and
#     still reads the row.
#   * _partition_ordinal_of parses p<digits> and returns -1 for anything else,
#     including a byte just below '0' and just above '9'.
# =============================================================================

from std.testing import assert_equal, assert_false, assert_true

from komira_objectstore.shared_in_memory_conditional_store import (
    SharedInMemoryConditionalStore,
)

from komira_table_store.table_store_codec import bytes_eq
from komira_table_store.partitioned_table_store import (
    PART_SPEC_HASH,
    PartitionSpec,
    PartitionedTableStore,
    _partition_ordinal_of,
    hash_shard_to_id,
    is_cross_shard_unsupported,
)


comptime _PS = PartitionedTableStore[SharedInMemoryConditionalStore]


def _b(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    var sb = s.as_bytes()
    for i in range(len(sb)):
        out.append(sb[i])
    return out^


def test_degenerate_shard_counts() raises:
    print("[part-edges] k <= 1 routes to shard 0; a k=0 spec opens one shard")
    var keys = List[String]()
    keys.append(String(""))
    keys.append(String("a"))
    keys.append(String("user-12345"))
    # The counts come from a list, not literals, so the call is not folded.
    var counts = List[Int]()
    counts.append(1)
    counts.append(0)
    counts.append(-3)
    for i in range(len(keys)):
        for j in range(len(counts)):
            assert_equal(
                hash_shard_to_id(_b(keys[i]), counts[j]),
                0,
                "k=" + String(counts[j]) + " key " + keys[i],
            )
    var ps = _PS.open(
        SharedInMemoryConditionalStore(),
        String("t0"),
        PartitionSpec(PART_SPEC_HASH, 0, List[List[UInt8]]()),
    )
    assert_equal(ps.shard_count(), 1, "k=0 opens one shard")
    assert_false(ps.is_partitioned(), "k=0 is not partitioned")


def test_route_range_hash_and_none_cover_all() raises:
    print("[part-edges] route_range: HASH -> every shard, NONE -> shard 0")
    var hs = _PS.open(
        SharedInMemoryConditionalStore(), String("th"), PartitionSpec.hash(3)
    )
    var got = hs.route_range(_b("a"), _b("b"), True, True)
    assert_equal(len(got), 3, "HASH covers all three shards")
    for i in range(3):
        assert_equal(got[i], i, "HASH slot " + String(i))
    var ns = _PS.open(
        SharedInMemoryConditionalStore(), String("tn"), PartitionSpec.none()
    )
    var one = ns.route_range(_b("a"), _b("b"), False, False)
    assert_equal(len(one), 1, "NONE covers its single shard")
    assert_equal(one[0], 0)


def test_begin_shard_mismatch_and_read_only() raises:
    print("[part-edges] begin on 0 + write routed to 1 refused; read-only commits")
    var bounds = List[List[UInt8]]()
    bounds.append(_b("m"))
    var ps = _PS.open(
        SharedInMemoryConditionalStore(), String("tr"), PartitionSpec.range(bounds^)
    )
    var t = ps.begin_on(0)
    t.insert(_b("z"), _b("v"))
    var err = String("")
    try:
        _ = ps.commit(t^)
    except e:
        err = String(e)
    assert_true(is_cross_shard_unsupported(err), "cross-shard token: " + err)
    assert_true(
        err.find("txn begun on shard slot 0 but its write-set routes to shard slot 1")
        >= 0,
        "names both slots: " + err,
    )
    var check = ps.begin_for_key(_b("z"))
    assert_false(Bool(ps.get(check, _b("z"))), "the refused write left no row")
    ps.abort_on(1, check^)

    var ro = ps.begin_on(0)
    var r = ps.commit(ro^)
    assert_false(r.did_append, "a read-only commit appends nothing")
    assert_equal(r.commit_lsn, Int64(-1), "read-only commit_lsn")


def test_reopen_with_smaller_k_refused() raises:
    print("[part-edges] reopen with K below a live shard ordinal is refused")
    var backing = SharedInMemoryConditionalStore()
    var key3 = String("")
    for i in range(200):
        var k = String("key-") + String(i)
        if hash_shard_to_id(_b(k), 4) == 3:
            key3 = k
            break
    assert_true(key3.byte_length() > 0, "found a key on shard 3")
    var ps4 = _PS.open(backing.clone(), String("tk"), PartitionSpec.hash(4))
    var t = ps4.begin_for_key(_b(key3))
    t.insert(_b(key3), _b("v3"))
    _ = ps4.commit(t^)

    var err = String("")
    try:
        _ = _PS.open(backing.clone(), String("tk"), PartitionSpec.hash(3))
    except e:
        err = String(e)
    assert_true(
        err.find("reopen-with-smaller-K: durable partition shard p3 exists") >= 0
        and err.find("but spec.k=3") >= 0
        and err.find("Reopen with K >= 4") >= 0,
        "k=3 reopen refused: " + err,
    )

    var again = _PS.open(backing.clone(), String("tk"), PartitionSpec.hash(4))
    var rt = again.begin_for_key(_b(key3))
    var got = again.get(rt, _b(key3))
    assert_true(Bool(got) and bytes_eq(got.value(), _b("v3")), "k=4 reopen reads")


def test_partition_ordinal_of() raises:
    print("[part-edges] _partition_ordinal_of: p<digits> or -1")
    assert_equal(_partition_ordinal_of(String("p0")), 0)
    assert_equal(_partition_ordinal_of(String("p7")), 7)
    assert_equal(_partition_ordinal_of(String("p12")), 12)
    assert_equal(_partition_ordinal_of(String("p909")), 909)
    var bad = List[String]()
    bad.append(String(""))
    bad.append(String("p"))
    bad.append(String("_base"))
    bad.append(String("q1"))
    bad.append(String("p1x"))
    bad.append(String("p/"))
    bad.append(String("p:"))
    for i in range(len(bad)):
        assert_equal(_partition_ordinal_of(bad[i]), -1, "not a partition id: " + bad[i])


def main() raises:
    test_degenerate_shard_counts()
    test_route_range_hash_and_none_cover_all()
    test_begin_shard_mismatch_and_read_only()
    test_reopen_with_smaller_k_refused()
    test_partition_ordinal_of()
    print("ALL partitioned table store edge tests PASSED")
