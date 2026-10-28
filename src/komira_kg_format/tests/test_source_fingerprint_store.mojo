# =============================================================================
# test_source_fingerprint_store.mojo -- the fingerprint lineage on an object
#   store (an in-memory conditional-write store; no network, no clock).
# =============================================================================
#
#   fresh         a lineage nothing was saved to loads as an empty set, and an
#                 empty set saved onto it writes nothing.
#   save, load    a saved set loads back; the latest save is the current set;
#                 load, patch one key and save keeps every other key.
#   guard         saving an empty set over a stored one is refused and the
#                 stored set is intact.
#   handles       a second handle on the same store (a fresh reader) loads the
#                 latest set after the first handle saved several times.
#   lineages      two prefixes on one store are independent, and the set lives at
#                 <prefix>/fingerprints, leaving the snapshot lineage alone.
#   corrupt       a chunk that does not decode (garbage, an unknown version) makes
#                 load an error, never an empty or partial set.
# =============================================================================

from std.testing import (
    TestSuite,
    assert_equal,
    assert_false,
    assert_raises,
    assert_true,
)

from komira_kg_format import SourceFingerprintSet, SourceFingerprintStore
from komira_objectstore.cas_manifest import CasManifestStore
from komira_objectstore.shared_in_memory_conditional_store import (
    SharedInMemoryConditionalStore,
)


comptime Store = SourceFingerprintStore[SharedInMemoryConditionalStore]


def _set(a: String, b: String) raises -> SourceFingerprintSet:
    var s = SourceFingerprintSet()
    s.patch("p1", "doc-1", a, "")
    s.patch("p1", "doc-2", b, "")
    return s^


def test_a_fresh_lineage_loads_empty_and_an_empty_save_writes_nothing() raises:
    var backend = SharedInMemoryConditionalStore()
    var store = Store(backend.clone(), "kg")
    assert_true(store.load().is_empty())
    store.save(SourceFingerprintSet())  # empty onto empty: a no-op
    assert_true(store.load().is_empty())
    var manifest = CasManifestStore[SharedInMemoryConditionalStore](
        backend.clone(), "kg/fingerprints"
    )
    assert_equal(manifest.read_head_fresh().chunk_seq, -1)


def test_save_then_load_and_latest_save_wins() raises:
    var backend = SharedInMemoryConditionalStore()
    var store = Store(backend.clone(), "kg")
    store.save(_set("1111111111111111", "2222222222222222"))
    var first = store.load()
    assert_equal(first.lookup("p1", "doc-1"), "1111111111111111")
    store.save(_set("3333333333333333", "2222222222222222"))
    var second = store.load()
    assert_equal(second.lookup("p1", "doc-1"), "3333333333333333")
    assert_equal(second.num_entries(), 2)


def test_load_patch_save_keeps_the_other_keys() raises:
    var backend = SharedInMemoryConditionalStore()
    var store = Store(backend.clone(), "kg")
    store.save(_set("1111111111111111", "2222222222222222"))
    var loaded = store.load()
    loaded.patch("p1", "doc-2", "4444444444444444", "")
    loaded.patch("p2", "doc-9", "5555555555555555", "")
    store.save(loaded^)
    var now = store.load()
    assert_equal(now.num_entries(), 3)
    assert_equal(now.lookup("p1", "doc-1"), "1111111111111111")
    assert_equal(now.lookup("p1", "doc-2"), "4444444444444444")
    assert_equal(now.lookup("p2", "doc-9"), "5555555555555555")


def test_saving_an_empty_set_over_a_stored_one_is_refused() raises:
    var backend = SharedInMemoryConditionalStore()
    var store = Store(backend.clone(), "kg")
    store.save(_set("1111111111111111", "2222222222222222"))
    with assert_raises(contains="refusing to replace a stored fingerprint set"):
        store.save(SourceFingerprintSet())
    assert_equal(store.load().num_entries(), 2)
    # A fresh handle refuses too: the guard reads the store, not a local cache.
    var other = Store(backend.clone(), "kg")
    with assert_raises(contains="refusing to replace a stored fingerprint set"):
        other.save(SourceFingerprintSet())
    assert_equal(other.load().num_entries(), 2)


def test_a_fresh_handle_loads_the_latest_set() raises:
    var backend = SharedInMemoryConditionalStore()
    var writer = Store(backend.clone(), "kg")
    for i in range(7):
        var s = SourceFingerprintSet()
        s.patch("p1", "doc-1", "000000000000000" + String(i), "")
        writer.save(s^)
    var reader = Store(backend.clone(), "kg")
    assert_equal(reader.load().lookup("p1", "doc-1"), "0000000000000006")


def test_prefixes_are_independent_lineages() raises:
    var backend = SharedInMemoryConditionalStore()
    var a = Store(backend.clone(), "graph-a")
    var b = Store(backend.clone(), "graph-b")
    a.save(_set("1111111111111111", "2222222222222222"))
    assert_true(b.load().is_empty())
    b.save(_set("9999999999999999", "8888888888888888"))
    assert_equal(a.load().lookup("p1", "doc-1"), "1111111111111111")
    assert_equal(b.load().lookup("p1", "doc-1"), "9999999999999999")


def test_the_set_lives_at_prefix_slash_fingerprints() raises:
    var backend = SharedInMemoryConditionalStore()
    var store = Store(backend.clone(), "kg")
    store.save(_set("1111111111111111", "2222222222222222"))
    var manifest = CasManifestStore[SharedInMemoryConditionalStore](
        backend.clone(), "kg/fingerprints"
    )
    var head = manifest.read_head_fresh()
    assert_equal(head.chunk_seq, 0)
    var body = SourceFingerprintSet.decode(manifest.read_chunk(head.chunk_seq))
    assert_equal(body.num_entries(), 2)
    var snapshots = CasManifestStore[SharedInMemoryConditionalStore](
        backend.clone(), "kg/manifest"
    )
    assert_equal(snapshots.read_head_fresh().chunk_seq, -1)


def test_a_chunk_that_does_not_decode_is_an_error_not_an_empty_set() raises:
    var backend = SharedInMemoryConditionalStore()
    var store = Store(backend.clone(), "kg")
    store.save(_set("1111111111111111", "2222222222222222"))
    var manifest = CasManifestStore[SharedInMemoryConditionalStore](
        backend.clone(), "kg/fingerprints"
    )
    var garbage: List[UInt8] = [1, 2, 3]
    _ = manifest.append(garbage^, 1)
    var fresh = Store(backend.clone(), "kg")
    with assert_raises(contains="truncated"):
        _ = fresh.load()

    var unknown = SourceFingerprintSet().encode()
    unknown[0] = 7
    _ = manifest.append(unknown^, 1)
    var again = Store(backend.clone(), "kg")
    with assert_raises(contains="unsupported fingerprint format version 7"):
        _ = again.load()


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
