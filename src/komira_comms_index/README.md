# komira_comms_index

The comms metadata and query-index substrate on `komira_objectstore`. One `CommsIndex[Store]` is the index of one collection (a mailbox, a calendar collection, a chat room): a delta log of immutable chunks behind a mutable `_HEAD` pointer, in any `ConditionalWriteStore`. It names no cloud client and wires no server; the caller picks the store and the collection's key prefix, and each comms type supplies its own key and value bytes.

## Layout

The log is a `CasManifestStore` of `komira_objectstore` under the collection's prefix:

- each chunk is an immutable object at its `chunk_seq` slot, written with the store's create-if-absent condition, so two writers racing for one slot have exactly one winner and the loser retries on the next slot;
- `_HEAD` is the mutable tail pointer, a cache that a reader can rebuild by listing, so a stale `_HEAD` costs a listing and never a lost delta;
- `_LOG_START` is the compaction watermark: chunks below it are folded into a base chunk and are reclaimed through the manifest's lifecycle (staged, published, scheduled for delete).

A chunk is either a delta (`CHUNK_KIND_DELTA`) holding one `KeyedDelta`, or a compacted base (`CHUNK_KIND_BASE`) holding the surviving deltas of the folded range. The codecs are in `comms_chunk_codec.mojo`; the byte formats are part of what is stored, so they do not change.

## Surface

| call | does |
|---|---|
| `CommsIndex[Store](store, prefix)` | opens the index of one collection |
| `put_delta(KeyedDelta) -> Int64` | appends a put or a tombstone; returns the `chunk_seq` it won, which is the sync token |
| `read_state() -> CommsState` | the merged state: per key the delta with the highest `seq` wins, a tombstone removes the key |
| `read_deltas_since(token) -> List[CommsDelta]` | the deltas after a token, for incremental sync (the shape of an RFC 6578 sync-collection report) |
| `compact() -> Int64` | folds the tail into one base chunk and advances the watermark; a concurrent append is not lost |
| `purge() -> Int64` | deletes the whole collection |
| `head_seq()`, `log_start_seq()`, `num_live_chunks()` | introspection |

`KeyedDelta.put`, `KeyedDelta.tombstone`, `key_bytes`, `bytes_equal`, `encode_keyed_delta` and `decode_keyed_delta` are the value helpers. No public signature takes or returns a pointer.

## Test

`tests/test_comms_index_substrate.mojo` is welded into the library build. It covers the chunk codec round trip, append and read, the fold of a mutable bit, compaction (state preserved, window, the watermark against a concurrent append), a fresh reader seeing a deferred tail, and the `_HEAD` race: four writers fanned out on worker threads with `ParallelDispatch` over one shared in-memory store, which must win distinct, gap-free `chunk_seq` slots with every delta readable.
