# =============================================================================
# komira_search_e2e/catalog.mojo
#   The glue a deployment writes between the split catalog and the scan kind,
#   written here for the tests: publish a split (object first, then the
#   manifest chunk), open a cold metastore handle, reap a retired split the
#   way the catalog's contract tells a caller to, and a `SearchIndexCatalog`
#   that answers the `komira.search.index` scan from a `SearchMetastore`.
# =============================================================================
#
# Every handle here is built over a CLONE of the store the caller passes, and
# a "cold" handle is a fresh `SearchMetastore` with an empty head cache, so
# whatever it reports comes from the objects in the store (for
# `LocalFsConditionalStore`, the files in its root directory).
#
# THE CATALOG'S GENERATION IS NOT `SearchMetastore.generation()`. That counts
# the chunks ever committed, so a retire (and a reap) leaves it where it was
# while the live split set shrinks. The `SearchIndexCatalog` contract needs a
# token that changes whenever the live set changes, and splits served by
# ordinal from one stable set per token. So `MetastoreSearchCatalog`:
#   * reports `2 * committed - live` (committed = `SearchMetastore.generation()`,
#     live = the live split count). A publish adds one committed chunk and at
#     most one live split, so the token rises; a retire removes a live split,
#     so it rises by one; a reap changes neither. It never goes down.
#   * records, on each `generation()` call, the object keys live at that
#     token in a snapshot object `<index>/catalog/generation-<token>`
#     (create-if-absent; a second writer of the same token must hold the same
#     keys, or the call raises). `split_count_at`/`split_at` read that record,
#     so a retire between `plan_splits` and `open_split` does not shift the
#     ordinals: an execution resolved before the retire still reads the split
#     objects it planned, which stay on disk until the reap. A token with no
#     record is refused by name (`SEARCH_GENERATION_NOT_AVAILABLE`).
# A snapshot record outlives the reap of a split it names; reading it after
# the reap fails with the store's not-found, which is the grace period's
# contract (it must exceed the longest query), not a silent drop.
#
# No pointers: every value is owned data or a store handle held by value.
# =============================================================================

from komira_objectstore import (
    AppendResult,
    CasManifestStore,
    RetryPolicy,
    WritePrecondition,
)
from komira_objectstore.cas_manifest import is_not_found, is_precondition
from komira_objectstore.path import Path
from komira_objectstore.store import CloneableConditionalWriteStore

from komira_search.analyzer import AnalyzerConfig

from komira_search_catalog.metastore import SearchMetastore
from komira_search_catalog.split_summary import SplitSummary, make_split_summary

from komira_search_scan.search_scan_kind import (
    SEARCH_GENERATION_NOT_AVAILABLE,
    SEARCH_INDEX_UNKNOWN,
    SEARCH_SPLIT_KEY_INVALID,
    SearchIndexCatalog,
)

from komira_search_e2e.corpus import TEXT_FIELD, split_uuid


def lineage_prefix(index: String) -> String:
    """The manifest lineage of `index`: `<index>/meta`."""
    return index + String("/meta")


def split_object_key(index: String, split: Int) -> String:
    """Where split `split`'s bytes live: `<index>/splits/split-<n>.split`."""
    return index + String("/splits/split-") + String(split) + String(".split")


def open_metastore[
    S: CloneableConditionalWriteStore
](store: S, index: String, retry: RetryPolicy) -> SearchMetastore[S]:
    """A metastore handle over a clone of `store`, with an empty head cache:
    its first read comes from the store's objects."""
    var manifest = CasManifestStore[S](
        store.clone(), lineage_prefix(index), retry
    )
    return SearchMetastore[S](manifest^, index.copy())


def cold_metastore[
    S: CloneableConditionalWriteStore
](store: S, index: String) -> SearchMetastore[S]:
    return open_metastore(store, index, RetryPolicy.fast_test())


def publish_split[
    S: CloneableConditionalWriteStore
](
    mut meta: SearchMetastore[S],
    store: S,
    index: String,
    split: Int,
    split_bytes: List[UInt8],
    doc_count: Int,
) raises -> AppendResult:
    """Publish split `split` the way `SearchMetastore.publish` requires: the
    split object is written first, then its summary is appended."""
    var key = split_object_key(index, split)
    _ = store.put(Path.parse(key), split_bytes)
    return meta.publish(
        make_split_summary(
            split_uuid(split),
            Int64(doc_count),
            Int64(len(split_bytes)),
            Int64(0),
            Int64(doc_count - 1),
            index.copy(),
            String(TEXT_FIELD),
            key^,
        )
    )


def reap_retired_split[
    S: CloneableConditionalWriteStore
](
    mut meta: SearchMetastore[S],
    store: S,
    chunk_seq: Int64,
    now_ms: Int64,
    grace_ms: Int64,
) raises -> Bool:
    """The caller's half of a reap (`SearchMetastore.reap_chunk`): when
    `chunk_seq` is tombstoned, read the split object's key while the chunk
    still records it, let the catalog reap the chunk, and delete the split
    object exactly when the catalog says the chunk is reaped. A chunk that is
    not tombstoned (never retired, or already reaped) is passed to
    `reap_chunk` and nothing is deleted: `tombstoned_chunk_object_key` reads
    any chunk that holds a summary, so reading the key without the tombstone
    check would delete a LIVE split's object. Returns what `reap_chunk`
    returned."""
    var tombstoned = True
    try:
        _ = meta.tombstone_schedule_ts(chunk_seq)
    except e:
        if not is_not_found(String(e)):
            raise e^
        tombstoned = False
    if not tombstoned:
        return meta.reap_chunk(chunk_seq, now_ms, grace_ms)
    var key = String("")
    try:
        key = meta.tombstoned_chunk_object_key(chunk_seq)
    except e:
        if not is_not_found(String(e)):
            raise e^
    if not meta.reap_chunk(chunk_seq, now_ms, grace_ms):
        return False
    if key.byte_length() > 0:
        store.delete(Path.parse(key))
    return True


def live_split_bytes[
    S: CloneableConditionalWriteStore
](store: S, live: List[SplitSummary]) raises -> List[List[UInt8]]:
    """The bytes of every split in `live`, read from `store`."""
    var out = List[List[UInt8]]()
    for i in range(len(live)):
        out.append(store.get(Path.parse(live[i].object_key)))
    return out^


def catalog_snapshot_key(index: String, generation: Int64) -> String:
    """Where `MetastoreSearchCatalog` records the object keys live at its
    token `generation`: `<index>/catalog/generation-<token>`."""
    return index + String("/catalog/generation-") + String(generation)


def _encode_keys(keys: List[String]) -> List[UInt8]:
    """The keys joined by newlines (an object key holds no newline)."""
    var out = List[UInt8]()
    for i in range(len(keys)):
        if i > 0:
            out.append(UInt8(10))
        var b = keys[i].as_bytes()
        for j in range(len(b)):
            out.append(b[j])
    return out^


def _key_string(var buf: List[UInt8]) -> String:
    # SAFETY: `buf` is a run of bytes `_encode_keys` copied out of a String,
    # cut at an ASCII newline, so it is whole UTF-8.
    return String(unsafe_from_utf8=Span(buf))


def _decode_keys(bytes: List[UInt8]) raises -> List[String]:
    var out = List[String]()
    if len(bytes) == 0:
        return out^
    var cur = List[UInt8]()
    for i in range(len(bytes)):
        if bytes[i] == UInt8(10):
            out.append(_key_string(cur^))
            cur = List[UInt8]()
        else:
            cur.append(bytes[i])
    out.append(_key_string(cur^))
    return out^


def _same_bytes(a: List[UInt8], b: List[UInt8]) -> Bool:
    if len(a) != len(b):
        return False
    for i in range(len(a)):
        if a[i] != b[i]:
            return False
    return True


struct MetastoreSearchCatalog[S: CloneableConditionalWriteStore](
    SearchIndexCatalog, Movable, Deinitable
):
    """A `SearchIndexCatalog` over one index's `SearchMetastore`. Every call
    opens a cold handle. `generation()` reports `2 * committed - live` and
    records the object keys live at that token; the split reads serve that
    record, in publish order (see the file header)."""

    var _store: Self.S
    var _index: String

    def __init__(out self, var store: Self.S, var index: String):
        self._store = store^
        self._index = index^

    def _check_index(self, index: String) raises:
        if index != self._index:
            raise Error(
                String(SEARCH_INDEX_UNKNOWN)
                + String(": no search index '")
                + index
                + String("' in this catalog")
            )

    def generation(self, index: String) raises -> Int64:
        """The token of the current live set, after recording its keys."""
        self._check_index(index)
        var meta = cold_metastore(self._store, self._index)
        # Live, committed, live again: a token is recorded only for a live
        # list that did not move around the committed count it is paired with.
        for _ in range(8):
            var before = meta.list_live_splits()
            var committed = meta.generation()
            var live = meta.list_live_splits()
            if not _same_keys(before, live):
                continue
            var token = Int64(2) * committed - Int64(len(live))
            var keys = List[String]()
            for i in range(len(live)):
                keys.append(live[i].object_key.copy())
            self._record(token, _encode_keys(keys))
            return token
        raise Error(
            String("komira_search_e2e: the live split set of '")
            + index
            + String("' kept moving while its generation was read")
        )

    def _record(self, token: Int64, encoded: List[UInt8]) raises:
        var key = Path.parse(catalog_snapshot_key(self._index, token))
        try:
            _ = self._store.conditional_put(
                key, encoded, WritePrecondition.if_none_match_star()
            )
        except e:
            if not is_precondition(String(e)):
                raise e^
            if not _same_bytes(self._store.get(key), encoded):
                raise Error(
                    String("komira_search_e2e: generation ")
                    + String(token)
                    + String(" of '")
                    + self._index
                    + String("' is recorded with a different live set")
                )

    def analyzer(self, index: String, field: String) raises -> AnalyzerConfig:
        self._check_index(index)
        if field != String(TEXT_FIELD):
            raise Error(
                String(SEARCH_INDEX_UNKNOWN)
                + String(": index '")
                + index
                + String("' has no analyzed field '")
                + field
                + String("'")
            )
        return AnalyzerConfig.text(field)

    def fields(self, index: String) raises -> List[String]:
        self._check_index(index)
        return [String(TEXT_FIELD)]

    def splits_at(
        self, index: String, generation: Int64
    ) raises -> List[List[UInt8]]:
        var keys = self._keys_at(index, generation)
        var out = List[List[UInt8]]()
        for i in range(len(keys)):
            out.append(self._store.get(Path.parse(keys[i])))
        return out^

    def split_count_at(self, index: String, generation: Int64) raises -> Int:
        return len(self._keys_at(index, generation))

    def split_at(
        self, index: String, generation: Int64, ordinal: Int
    ) raises -> List[UInt8]:
        var keys = self._keys_at(index, generation)
        if ordinal < 0 or ordinal >= len(keys):
            raise Error(
                String(SEARCH_SPLIT_KEY_INVALID)
                + String(": index '")
                + index
                + String("' has ")
                + String(len(keys))
                + String(" splits at generation ")
                + String(generation)
                + String("; split ")
                + String(ordinal)
                + String(" is not one of them")
            )
        return self._store.get(Path.parse(keys[ordinal]))

    def _keys_at(self, index: String, generation: Int64) raises -> List[String]:
        """The object keys recorded for `generation`, refused by name when no
        `generation()` call recorded that token."""
        self._check_index(index)
        var raw: List[UInt8]
        try:
            raw = self._store.get(
                Path.parse(catalog_snapshot_key(self._index, generation))
            )
        except e:
            if not is_not_found(String(e)):
                raise e^
            raise Error(
                String(SEARCH_GENERATION_NOT_AVAILABLE)
                + String(": index '")
                + index
                + String("' has no recorded generation ")
                + String(generation)
            )
        return _decode_keys(raw)


def _same_keys(a: List[SplitSummary], b: List[SplitSummary]) -> Bool:
    if len(a) != len(b):
        return False
    for i in range(len(a)):
        if a[i].object_key != b[i].object_key:
            return False
    return True
