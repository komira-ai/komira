# =============================================================================
# test_search_e2e_catalog_generation.mojo
#   `MetastoreSearchCatalog.generation()` pairs a live split set with a
#   generation only when the generation held across the live read.
# =============================================================================
#
# The three corpus splits are published into a `LocalFsConditionalStore`
# rooted in TEST_TMPDIR. The catalog then reads through `_BumpAfterRead`, a
# store that, each time the lineage's `_GENERATION_BUMPS` counter is read
# while a budget object on disk is above zero, answers with the value it
# read and THEN adds one to the counter (what `retire` and `reap_chunk` do
# around their change), so the next generation read differs. The budget
# lives in the store, not in the wrapper, because the catalog clones its
# store for every handle.
#
#   1. test_a_generation_that_moved_during_the_read_is_read_again: budget 2,
#      so the first attempt's two generation reads disagree (each bumps after
#      it reads) and the second attempt's agree. The catalog must
#      read again and return the generation a cold metastore reports once
#      the bumps stop, record the three live split keys under it, and a scan
#      at it must equal the baseline. Defect caught: a catalog that records
#      the live set under a generation that moved during the read (planted:
#      drop the `continue`; the returned generation is then below the
#      metastore's).
#   2. test_a_generation_that_never_settles_is_refused: an unbounded budget,
#      so every attempt's reads disagree. The catalog must raise by name
#      ("kept changing") and record nothing, never pick one of the moving
#      values. Defect caught: a catalog that gives up silently with a
#      generation it could not pair with a live set.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_raises, assert_true

from komira_objectstore import (
    CoalescePolicy,
    ListResult,
    LocalFsConditionalStore,
    ObjectMeta,
    RetryPolicy,
    WritePrecondition,
)
from komira_objectstore.cas_manifest import is_not_found
from komira_objectstore.path import Path
from komira_objectstore.store import (
    CloneableConditionalWriteStore,
    ConditionalWriteStore,
    ObjectStore,
)

from komira_search_catalog.generation import (
    bump_generation,
    generation_bumps_key,
)

from komira_search_scan.search_scan_kind import SearchScanResolver

from komira_runtime_paths import test_tmpdir

from komira_search_e2e.corpus import (
    INDEX_NAME,
    NUM_SPLITS,
    corpus_split,
    split_doc_count,
)
from komira_search_e2e.catalog import (
    MetastoreSearchCatalog,
    catalog_snapshot_key,
    cold_metastore,
    lineage_prefix,
    open_metastore,
    publish_split,
    split_object_key,
)
from komira_search_e2e.rows import baseline_rows, scan_rows


comptime _BUDGET_KEY = "e2e_bump_budget"


struct _BumpAfterRead(
    CloneableConditionalWriteStore,
    ConditionalWriteStore,
    ObjectStore,
    Movable,
    Deinitable,
):
    """A LocalFsConditionalStore that, on a read of `_lineage`'s generation
    counter while the budget object holds a count above zero, bumps the
    counter after the read and takes one from the budget (255 is never taken
    from). Plain owned data; `clone()` copies it."""

    var _inner: LocalFsConditionalStore
    var _lineage: String

    def __init__(out self, var inner: LocalFsConditionalStore, var lineage: String):
        self._inner = inner^
        self._lineage = lineage^

    def clone(self) -> Self:
        return Self(self._inner.clone(), self._lineage.copy())

    def _is_counter(self, path: Path) raises -> Bool:
        return path.raw() == generation_bumps_key(self._lineage).raw()

    def _maybe_bump(self) raises:
        var left: List[UInt8]
        try:
            left = self._inner.get(Path.parse(String(_BUDGET_KEY)))
        except e:
            if is_not_found(String(e)):
                return
            raise e^
        if len(left) == 0 or left[0] == UInt8(0):
            return
        if left[0] != UInt8(255):  # 255: unbounded
            _ = self._inner.put(
                Path.parse(String(_BUDGET_KEY)), [left[0] - UInt8(1)]
            )
        bump_generation(self._inner, self._lineage)

    def head(self, path: Path) raises -> ObjectMeta:
        return self._inner.head(path)

    def list_with_delimiter(self, prefix: Path) raises -> ListResult:
        return self._inner.list_with_delimiter(prefix)

    def coalesce_policy(self) -> CoalescePolicy:
        return self._inner.coalesce_policy()

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

    def get_range(
        self, path: Path, start: Int64, length: Int64
    ) raises -> List[UInt8]:
        if not self._is_counter(path):
            return self._inner.get_range(path, start, length)
        var got: List[UInt8]
        try:
            got = self._inner.get_range(path, start, length)
        except e:
            self._maybe_bump()
            raise e^
        self._maybe_bump()
        return got^

    def get(self, path: Path) raises -> List[UInt8]:
        if not self._is_counter(path):
            return self._inner.get(path)
        var got: List[UInt8]
        try:
            got = self._inner.get(path)
        except e:
            self._maybe_bump()
            raise e^
        self._maybe_bump()
        return got^

    def delete(self, path: Path) raises -> None:
        self._inner.delete(path)


def _publish_corpus(root: String, index: String) raises -> List[List[UInt8]]:
    var store = LocalFsConditionalStore(root)
    var writer = open_metastore(store, index, RetryPolicy.fast_test())
    var splits = List[List[UInt8]]()
    for s in range(NUM_SPLITS):
        splits.append(corpus_split(s))
        _ = publish_split(writer, store, index, s, splits[s], split_doc_count(s))
    return splits^


def _set_budget(root: String, n: UInt8) raises:
    _ = LocalFsConditionalStore(root).put(Path.parse(String(_BUDGET_KEY)), [n])


def _bumping(root: String, index: String) raises -> _BumpAfterRead:
    return _BumpAfterRead(LocalFsConditionalStore(root), lineage_prefix(index))


def _absent(store: LocalFsConditionalStore, key: Path) raises -> Bool:
    try:
        _ = store.get(key)
    except e:
        if is_not_found(String(e)):
            return True
        raise e^
    return False


def test_a_generation_that_moved_during_the_read_is_read_again() raises:
    var root = test_tmpdir() + String("/catalog_gen_moves")
    var index = String(INDEX_NAME)
    var splits = _publish_corpus(root, index)
    var g_published = cold_metastore(LocalFsConditionalStore(root), index).generation()

    _set_budget(root, UInt8(2))
    var catalog = MetastoreSearchCatalog[_BumpAfterRead](
        _bumping(root, index), index.copy()
    )
    var got = catalog.generation(index)
    var plain = LocalFsConditionalStore(root)
    assert_equal(
        plain.get(Path.parse(String(_BUDGET_KEY)))[0],
        UInt8(0),
        "both bumps ran inside the catalog's first generation call",
    )
    var settled = cold_metastore(LocalFsConditionalStore(root), index).generation()
    assert_equal(settled, g_published + Int64(2), "two bumps landed")
    assert_equal(
        got,
        settled,
        "the catalog returned a generation that moved during its read",
    )
    assert_equal(
        catalog.split_count_at(index, got), NUM_SPLITS, "recorded split count"
    )
    for s in range(NUM_SPLITS):
        assert_equal(
            len(catalog.split_at(index, got, s)),
            len(splits[s]),
            "recorded split " + String(s),
        )
    var rt = SearchScanResolver[MetastoreSearchCatalog[_BumpAfterRead]](
        MetastoreSearchCatalog[_BumpAfterRead](
            _bumping(root, index), index.copy()
        )
    )
    var rows = scan_rows(rt, index, String("alpha"))
    assert_equal(rows.generation, settled, "the scan resolved the settled one")
    var want = baseline_rows(splits, String("alpha"))
    assert_equal(len(rows.rows), len(want), "scan row count")
    for i in range(len(want)):
        assert_equal(rows.rows[i], want[i], "scan row " + String(i))


def test_a_generation_that_never_settles_is_refused() raises:
    var root = test_tmpdir() + String("/catalog_gen_never_settles")
    var index = String(INDEX_NAME)
    _ = _publish_corpus(root, index)
    var g_published = cold_metastore(LocalFsConditionalStore(root), index).generation()

    _set_budget(root, UInt8(255))
    var catalog = MetastoreSearchCatalog[_BumpAfterRead](
        _bumping(root, index), index.copy()
    )
    with assert_raises(contains="kept changing"):
        _ = catalog.generation(index)
    _set_budget(root, UInt8(0))
    var after = cold_metastore(LocalFsConditionalStore(root), index).generation()
    assert_true(after > g_published, "the bumps moved the generation")
    var plain = LocalFsConditionalStore(root)
    var g = g_published
    while g <= after:
        assert_true(
            _absent(plain, Path.parse(catalog_snapshot_key(index, g))),
            "a split set was recorded under moving generation " + String(g),
        )
        g += Int64(1)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
