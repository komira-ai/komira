# comms_index

The comms metadata and query-index substrate on `objectstore`. One `CommsIndex[Store]` is the index of one collection (a mailbox, a calendar collection, a chat room): a delta log of immutable chunks behind a mutable `_HEAD` pointer, in any `ConditionalWriteStore`. It names no cloud client and wires no server; the caller picks the store and the collection's key prefix, and each comms type supplies its own key and value bytes.

## Layout

The log is a `CasManifestStore` of `objectstore` under the collection's prefix:

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

## Examples

Both examples run as tests when the package is built, so they cannot go stale.

### A delta and its codec

`KeyedDelta.put` and `KeyedDelta.tombstone` build the one record the log holds. `encode_keyed_delta` and `decode_keyed_delta` are the body codec and round-trip a delta exactly; `encode_compacted_base` and `decode_compacted_base` do the same for the survivors that compaction folds into a base chunk. `key_bytes` turns a string into key or value bytes, and `bytes_equal` compares two byte lists.

```mojo
from comms_index.comms_chunk_codec import (
    COMMS_BASE_VERSION,
    DELTA_OP_PUT,
    DELTA_OP_TOMBSTONE,
    KeyedDelta,
    bytes_equal,
    decode_compacted_base,
    decode_keyed_delta,
    delta_op_name,
    encode_compacted_base,
    encode_keyed_delta,
    key_bytes,
)
from std.testing import assert_equal, assert_false, assert_true

var put = KeyedDelta.put(Int64(7), key_bytes("uid:42"), key_bytes("\\Seen"))
var back = decode_keyed_delta(encode_keyed_delta(put))
assert_equal(back.op, DELTA_OP_PUT)
assert_equal(delta_op_name(back.op), "PUT")
assert_equal(Int(back.seq), 7)
assert_true(bytes_equal(back.key, key_bytes("uid:42")))
assert_true(bytes_equal(back.value, key_bytes("\\Seen")))
assert_false(back.is_tombstone())

var gone = KeyedDelta.tombstone(Int64(9), key_bytes("uid:42"))
var gone_back = decode_keyed_delta(encode_keyed_delta(gone))
assert_equal(gone_back.op, DELTA_OP_TOMBSTONE)
assert_true(gone_back.is_tombstone())
assert_equal(len(gone_back.value), 0)

var survivors = List[KeyedDelta]()
survivors.append(KeyedDelta.put(Int64(1), key_bytes("a"), key_bytes("A")))
survivors.append(KeyedDelta.put(Int64(2), key_bytes("bb"), key_bytes("BB")))
var base = decode_compacted_base(encode_compacted_base(survivors))
assert_equal(COMMS_BASE_VERSION, UInt8(1))
assert_equal(len(base), 2)
assert_true(bytes_equal(base[0].key, key_bytes("a")))
assert_true(bytes_equal(base[1].value, key_bytes("BB")))
```

### Append, read, sync and compact

This example opens an index over the in-memory conditional store, appends deltas, reads the merged state, asks for the changes after a sync token (a removed key shows up as `removed`), and compacts the tail into one base chunk. The merged state is the same before and after the compaction; only the number of live chunks drops.

```mojo
from comms_index.comms_chunk_codec import KeyedDelta, bytes_equal, key_bytes
from comms_index.comms_index import CommsIndex
from objectstore.in_memory_conditional_store import InMemoryConditionalStore
from std.testing import assert_equal, assert_false, assert_true

var idx = CommsIndex[InMemoryConditionalStore](
    InMemoryConditionalStore(), String("caldav/cal/_idx")
)
_ = idx.put_delta(KeyedDelta.put(Int64(0), key_bytes("a"), key_bytes("A1")))
var token = idx.put_delta(
    KeyedDelta.put(Int64(0), key_bytes("b"), key_bytes("B1"))
)
_ = idx.put_delta(KeyedDelta.tombstone(Int64(1), key_bytes("a")))
_ = idx.put_delta(KeyedDelta.put(Int64(1), key_bytes("b"), key_bytes("B2")))
assert_equal(Int(token), 1)
assert_equal(Int(idx.head_seq()), 3)

# Last writer wins per key, and a tombstone removes the key.
var state = idx.read_state()
assert_equal(state.len(), 1)
assert_false(state.contains(key_bytes("a")))
assert_true(bytes_equal(state.value_for(key_bytes("b")), key_bytes("B2")))

# Incremental sync: what changed after the token, removals included.
var changes = idx.read_deltas_since(token)
assert_equal(len(changes), 2)
assert_true(bytes_equal(changes[0].key, key_bytes("a")))
assert_true(changes[0].removed)
assert_equal(Int(changes[0].seq), 2)
assert_true(bytes_equal(changes[1].key, key_bytes("b")))
assert_false(changes[1].removed)
assert_true(bytes_equal(changes[1].value, key_bytes("B2")))

# Compaction keeps the state and leaves one live chunk, the base.
assert_equal(Int(idx.num_live_chunks()), 4)
var base_seq = idx.compact()
assert_equal(Int(idx.num_live_chunks()), 1)
assert_equal(Int(idx.log_start_seq()), Int(base_seq))
var after = idx.read_state()
assert_equal(after.len(), 1)
assert_true(bytes_equal(after.value_for(key_bytes("b")), key_bytes("B2")))
```
