# =============================================================================
# test_search_e2e_publish_race.mojo
#   Publishing a search index's splits to the local filesystem from two
#   handles whose cached heads go stale, so each loses a manifest slot to the
#   other, then reading the lineage cold.
# =============================================================================
#
# Every store here is a `LocalFsConditionalStore` rooted in this run's
# TEST_TMPDIR. Two store OBJECTS over one directory stand for two indexer
# processes: they share nothing but the files.
#
# WHAT "RACE" MEANS HERE. The two handles are interleaved deterministically:
# no threads, no sleeps. Every loss below is the 412 that
# `LocalFsConditionalStore.conditional_put` raises from its existence probe
# when the slot file is already there. The `O_EXCL` create that decides a
# truly simultaneous create (both probes pass, one `open` gets EEXIST) is NOT
# reached by this file; komira_objectstore's own tests own that branch.
#
#   1. test_create_if_absent_has_one_winner: two store objects create the same
#      key; the first wins, the second gets the precondition failure (the 412
#      every slot race turns on) and the file holds the winner's bytes.
#      Defect caught: a create that overwrites an existing object.
#   2. test_publish_race_and_cold_read: writer A publishes split 0 (slot 0);
#      writer B, a separate store object with no retries, publishes split 1
#      (slot 1); A's cached head still says slot 0, so A's publish of split 2
#      loses slot 1 to B, retries and lands at slot 2 (attempts >= 2). B's
#      next publish, from its own stale head, loses slot 2 and, with no
#      retries left, refuses as retryable contention; its split object is an
#      orphan nothing references. A COLD handle (a new store object over the
#      same directory) after every step reports the generation 0, 1, 2, 3, 3
#      and finally lists exactly splits 0, 1, 2 in publish order, with slot 2
#      holding A's split and slot 1 still holding B's. The durable `_HEAD`
#      object, read cold after every step, never moves backwards and never
#      runs past the true tail (`reap_chunk` caps its log-start advance by
#      it). Defects caught: a stale-head publish that clobbers a committed
#      chunk (B's split would vanish), a lost publish, a refused publish that
#      is visible anyway, a generation that does not move with a publish, and
#      a late head advance that writes `_HEAD` backwards.
# =============================================================================

from std.testing import (
    TestSuite,
    assert_equal,
    assert_false,
    assert_true,
)

from komira_objectstore import (
    LocalFsConditionalStore,
    RetryPolicy,
    WritePrecondition,
    chunk_key,
    decode_chunk_body,
    decode_head,
    head_key,
)
from komira_objectstore.cas_manifest import (
    is_not_found,
    is_precondition,
    is_retryable_contention,
)
from komira_objectstore.path import Path

from komira_search_catalog.split_summary import decode_split_summary

from komira_runtime_paths import test_tmpdir

from komira_search_e2e.corpus import (
    INDEX_NAME,
    NUM_SPLITS,
    corpus_split,
    split_doc_count,
    split_uuid,
    uuid_eq,
)
from komira_search_e2e.catalog import (
    cold_metastore,
    lineage_prefix,
    open_metastore,
    publish_split,
    split_object_key,
)


def _bytes(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    var b = s.as_bytes()
    for i in range(len(b)):
        out.append(b[i])
    return out^


def _same_bytes(a: List[UInt8], b: List[UInt8]) -> Bool:
    if len(a) != len(b):
        return False
    for i in range(len(a)):
        if a[i] != b[i]:
            return False
    return True


def _cold_generation(root: String) raises -> Int64:
    """The generation a fresh store object over `root` reports."""
    var store = LocalFsConditionalStore(root)
    var meta = cold_metastore(store, String(INDEX_NAME))
    return meta.generation()


def _durable_head_seq(root: String) raises -> Int64:
    """The chunk_seq the durable `_HEAD` object names, read through a new
    store object; -1 when there is no `_HEAD` object yet."""
    var store = LocalFsConditionalStore(root)
    try:
        return decode_head(
            store.get(head_key(lineage_prefix(String(INDEX_NAME))))
        ).chunk_seq
    except e:
        if is_not_found(String(e)):
            return Int64(-1)
        raise e^


def test_create_if_absent_has_one_winner() raises:
    var root = test_tmpdir() + String("/create_race")
    var a = LocalFsConditionalStore(root)
    var b = LocalFsConditionalStore(root)
    var key = Path.parse(String("race/slot.chunk"))
    _ = a.conditional_put(
        key, _bytes(String("from a")), WritePrecondition.if_none_match_star()
    )
    var lost = False
    try:
        _ = b.conditional_put(
            key, _bytes(String("from b")), WritePrecondition.if_none_match_star()
        )
    except e:
        assert_true(
            is_precondition(String(e)),
            "the loser's error is not a precondition failure: " + String(e),
        )
        lost = True
    assert_true(lost, "a second create of an existing key succeeded")
    var c = LocalFsConditionalStore(root)
    assert_true(
        _same_bytes(c.get(key), _bytes(String("from a"))),
        "the winner's bytes are on disk",
    )


def test_publish_race_and_cold_read() raises:
    var root = test_tmpdir() + String("/publish_race")
    var index = String(INDEX_NAME)
    var store_a = LocalFsConditionalStore(root)
    var store_b = LocalFsConditionalStore(root)
    var meta_a = open_metastore(store_a, index, RetryPolicy.fast_test())
    var meta_b = open_metastore(
        store_b, index, RetryPolicy(Int64(100), Int64(1000), 0)
    )
    var gens = List[Int64]()
    var heads = List[Int64]()
    gens.append(_cold_generation(root))
    heads.append(_durable_head_seq(root))

    var r0 = publish_split(
        meta_a, store_a, index, 0, corpus_split(0), split_doc_count(0)
    )
    assert_equal(r0.chunk_seq, Int64(0), "A's first publish takes slot 0")
    gens.append(_cold_generation(root))
    heads.append(_durable_head_seq(root))

    var r1 = publish_split(
        meta_b, store_b, index, 1, corpus_split(1), split_doc_count(1)
    )
    assert_equal(r1.chunk_seq, Int64(1), "B's first publish takes slot 1")
    gens.append(_cold_generation(root))
    heads.append(_durable_head_seq(root))

    # A still believes the head is slot 0, so it tries slot 1, which B holds.
    var r2 = publish_split(
        meta_a, store_a, index, 2, corpus_split(2), split_doc_count(2)
    )
    assert_equal(r2.chunk_seq, Int64(2), "A's retry lands at the next slot")
    assert_true(
        r2.attempts >= 2,
        "A's publish did not lose slot 1 first (attempts "
        + String(r2.attempts)
        + ")",
    )
    gens.append(_cold_generation(root))
    heads.append(_durable_head_seq(root))

    # B believes the head is slot 1, so it tries slot 2, which A now holds.
    # With no retries it refuses; the split object it wrote first is an
    # orphan that no chunk names.
    var refused = False
    try:
        _ = publish_split(
            meta_b, store_b, index, 7, corpus_split(1), split_doc_count(1)
        )
    except e:
        assert_true(
            is_retryable_contention(String(e)),
            "B's refusal is not retryable contention: " + String(e),
        )
        refused = True
    assert_true(refused, "B's stale publish was not refused")
    gens.append(_cold_generation(root))
    heads.append(_durable_head_seq(root))

    var want_gens: List[Int64] = [
        Int64(0), Int64(1), Int64(2), Int64(3), Int64(3)
    ]
    for i in range(len(want_gens)):
        assert_equal(
            gens[i],
            want_gens[i],
            "cold generation after step " + String(i),
        )
        # The true tail after step i is generation - 1.
        assert_true(
            heads[i] <= want_gens[i] - Int64(1),
            "the durable head after step "
            + String(i)
            + " names chunk "
            + String(heads[i])
            + ", past the tail",
        )
        if i > 0:
            assert_true(
                heads[i] >= heads[i - 1],
                "the durable head went backwards after step "
                + String(i)
                + ": "
                + String(heads[i - 1])
                + " -> "
                + String(heads[i]),
            )

    # A cold reader: a new store object over the same directory.
    var cold_store = LocalFsConditionalStore(root)
    var cold = cold_metastore(cold_store, index)
    var live = cold.list_live_splits()
    assert_equal(len(live), NUM_SPLITS, "a cold handle lists three splits")
    for s in range(NUM_SPLITS):
        assert_true(
            uuid_eq(live[s].split_uuid, split_uuid(s)),
            "live split " + String(s) + " is corpus split " + String(s),
        )
        assert_equal(live[s].object_key, split_object_key(index, s))
        assert_equal(live[s].doc_count, Int64(split_doc_count(s)))
        assert_false(
            uuid_eq(live[s].split_uuid, split_uuid(7)),
            "the refused publish is visible",
        )
    var with_seq = cold.list_live_splits_with_seq()
    for s in range(NUM_SPLITS):
        assert_equal(with_seq[s].chunk_seq, Int64(s), "split " + String(s) + " slot")

    # Slot 1 still holds B's split: A's losing attempt did not clobber it.
    var chunk1 = cold_store.get(chunk_key(lineage_prefix(index), Int64(1)))
    var s1 = decode_split_summary(decode_chunk_body(chunk1))
    assert_true(uuid_eq(s1.split_uuid, split_uuid(1)), "chunk 1 holds B's split")
    assert_equal(s1.object_key, split_object_key(index, 1), "chunk 1's key")

    # Slot 2 holds A's split, and no chunk exists past it.
    var chunk2 = cold_store.get(chunk_key(lineage_prefix(index), Int64(2)))
    assert_true(
        uuid_eq(
            decode_split_summary(decode_chunk_body(chunk2)).split_uuid,
            split_uuid(2),
        ),
        "chunk 2 on disk holds A's split 2",
    )
    var past = False
    try:
        _ = cold_store.get(chunk_key(lineage_prefix(index), Int64(3)))
    except e:
        past = is_not_found(String(e))
    assert_true(past, "a chunk exists past the three publishes")
    assert_equal(cold.generation(), Int64(3), "the cold generation is 3")

    # The objects the summaries name are the bytes that were published.
    for s in range(NUM_SPLITS):
        var on_disk = cold_store.get(Path.parse(live[s].object_key))
        assert_true(
            _same_bytes(on_disk, corpus_split(s)), "split object " + String(s)
        )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
