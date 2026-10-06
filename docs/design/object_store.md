# Object store: vendor-neutral object storage and the coordination primitives built on it

## What is it for, and what is out of scope?

`komira_objectstore` (`src/komira_objectstore`) gives stateful code a durable place to keep state in a bucket without a lock service. Its traits describe an object store whose conditional write (create-if-absent, or replace-if-version-matches) lets concurrent writers coordinate: a manifest chunk, a claim or a dedup record is an object whose creation exactly one writer wins. Around those traits the library ships local and in-memory conformers, the append-only CAS manifest, batching, compaction and sharding primitives built on the manifest, a presigned-URL seam, and a readiness probe. The distributed shuffle is built on top of it, in its own package, `komira_shuffle`.

The library imports `komira_core`, `komira_async` (the reactor, and the C shim that carries the manifest's process-wide lock), `komira_atomic_alias` and `komira_obs` (the metrics sink for list escalations).

Out of scope:

- Stores for a particular cloud. The traits here are what a cloud's object-store library conforms to, and those libraries are described with the cloud libraries, not here.
- Parsing the files that file systems read: see the Parquet and text-format docs when they land.
- The crypto behind signed URLs: see the crypto design doc (`crypto_and_tls.md`, on `main`).

## How does it work?

```
stateful services (a log, a catalog, a table store, a search index)
        |
   CasManifestStore, CoalescingWindow, compact_once, ShardedLineage,
   the shuffle (komira_shuffle: sink, seal, claim, source)
        |
   ConditionalWriteStore conformers
   LocalFsConditionalStore | the in-memory twins | a cloud store's conformer
```

### What do the store traits promise?

`store.mojo` defines a ladder of traits:

- `ObjectStore`: `head`, `list_with_delimiter` and `coalesce_policy`.
- `ConditionalWriteStore(ObjectStore)`: `conditional_put`, `compare_and_swap`, `put`, `get_range`, `get` and `delete`. `compare_and_swap` is `conditional_put` with `WritePrecondition.if_match`.
- `CloneableConditionalWriteStore`: `clone()` returns a handle that shares the same data, so one store can be fanned out into per-partition handles.
- `AsyncCasStore`: `read_start`/`read_poll`/`read_take` and `cas_put_start`/`cas_put_poll`/`cas_put_take`, a start-and-poll form of the read and the conditional write. At most one such operation is in flight per conformer.
- `RangeFetchStore`: `get_ranges`, a fan-out of ranged reads. Nothing in this library conforms to it.

`WritePrecondition` in `types.mojo` has four forms: none, `if_none_match_star`, `if_match(etag)` and `if_none_match(etag)`; `is_create()` is true for both `If-None-Match` forms. A successful write returns an `ObjectMeta` whose `etag` is the new version handle, so a caller can chain the next compare-and-swap on it without a `head`. The handle is an opaque string. `ObjectMeta.version` is a second field for stores that have a generation or version id; every conformer in this library leaves it empty, so callers chain on `etag`.

`Path` (`path.mojo`) strips leading `/`, collapses `//`, keeps a trailing `/`, and rejects `.` and `..` segments. `objectstore_uri.parse` recognizes `s3://`, `gs://`, `az://`, `abfs://` and `file://`.

Stores raise a plain `Error`; the message carries the error class. `StoreError` names six classes (not found, permission denied, throttled, precondition, transport, malformed), and `StoreError.is_retryable` is true only for throttled and transport.

### Which object store conformer should a test use?

| Conformer | Backing | Shares data on `clone()` |
|---|---|---|
| `InMemoryConditionalStore` | a map in one handle | no clone |
| `SharedInMemoryConditionalStore` | an `ArcPointer`-shared map | yes |
| `SharedInMemorySlowCasStore` | shared map, also an `AsyncCasStore` | yes |
| `SharedInMemoryLatencyStore` | shared map with added latency; for tests | yes |
| `DelimiterFaithfulConditionalStore` | shared map with real delimiter listing | yes |
| `LocalFsConditionalStore` | one file per key in a directory | yes, the clone is bound to the same directory |

Listing differs between them. `InMemoryConditionalStore`, `SharedInMemoryConditionalStore` and `LocalFsConditionalStore` return every key under the prefix in `objects` and leave `common_prefixes` empty. `DelimiterFaithfulConditionalStore` rolls keys one level deeper into `common_prefixes`, as a real bucket does. Code that folds only `objects` passes against the first group and misses keys one level deeper on a real bucket, so a test of directory-style listing should use `DelimiterFaithfulConditionalStore`.

### How does a compare-and-swap write work on each conformer?

- **Local directory.** Create-if-absent is `open(O_CREAT|O_EXCL)`, so the kernel admits one creator across processes. `If-Match` reads the current etag, compares, then writes a temporary file in the same directory and renames it over the key. The etag is a quoted FNV-1a-64 hex digest of the bytes, so two writes of identical bytes have identical etags.
- **In memory.** Etags are quoted monotone integers, and a failed condition raises an `Error` whose text contains `precondition`; the shared twins spell it `precondition (412)`.

`LocalFsConditionalStore` is the durable single-machine backend. Its header scopes it to one process and one thread; its create-if-absent write is exclusive across processes, but its `If-Match` write has a read-compare-write window, so it is not linearizable across processes.

### How are presigned URLs minted?

`ObjectUrlSigner` (`presign.mojo`) is the seam for minting a short-lived URL that lets a client GET or PUT one object directly. It has one method per verb, `presign_download` and `presign_upload`, so a signer cannot be asked to presign an arbitrary method. Every conformer calls `check_presign_ttl` before signing; it raises for a TTL outside 1 to `PRESIGN_MAX_TTL_SECONDS` (3600) seconds. The conformers belong to the cloud store libraries.

### How does the CAS manifest append work?

A CAS manifest (`cas_manifest.mojo`) is an ordered, append-only sequence of immutable chunks under a key prefix:

```
<prefix>/manifest/<chunk_seq, 20 digits>.chunk   one chunk per append
<prefix>/_HEAD                                    last known tail (a hint)
<prefix>/tombstones/<chunk_seq>.tomb              chunk scheduled for delete
<prefix>/moved_tombstones/<chunk_seq>.tomb        same, payload moved to another manifest
<prefix>/_LOG_START                               truncation point
<prefix>/_CATALOG                                 one opaque consumer blob
```

`CasManifestStore[Store: ConditionalWriteStore]` conforms to the `MetadataStore` trait. `append(body, record_count)` creates chunk `K+1` with `If-None-Match: *`; the creator of a slot owns it, so the sequence has no gaps. The returned `AppendResult` gives the chunk sequence and the offset range `[base_offset, last_offset]` the body occupies. The body is opaque to the manifest.

On a 412 the append sleeps with full-jitter exponential backoff (`RetryPolicy.default()`: 5 ms base, 250 ms cap, 8 retries; `broker_contention()`: 0.5 ms, 100 ms, 40). It then tries the next slot. After 3 consecutive 412s it lists the manifest prefix for the true top sequence and replays only the gap since its last head, instead of probing slot by slot, and it counts the escalation in its metrics sink when one is attached. When retries run out it raises a message containing `(retryable)`, which `is_retryable_contention` recognizes. A caller may pass `writer_lease_epoch` and `current_lease_epoch`, and an append whose writer epoch is lower raises `lease_fenced` before taking a slot.

The handle keeps its own last tail in `_LocalHeadCache`, so the next append skips reading `_HEAD`. An append that starts from this warm cache defers its `_HEAD` write, and the handle writes `_HEAD` once 64 appends have deferred it (`_HEAD_ADVANCE_DEFER_CADENCE`). An append that starts cold advances `_HEAD` with a conditional write as soon as it wins its slot. Cold includes the first append on a handle and every retry after a 412, since a 412 always leaves the cache cold. `try_append_at_seq` makes one attempt at an exact slot and never defers: a win advances `_HEAD` at once. Readers choose: `read_head` trusts the local cache, `read_head_fresh` lists the bucket when the cache is cold, `read_head_authoritative` always lists, and `read_durable_head` reads the `_HEAD` object once.

`schedule_for_delete` writes a tombstone and `reap` deletes the chunk. `schedule_moved_for_delete_at` writes a MOVED marker instead, at `<prefix>/moved_tombstones/<chunk_seq>.tomb`: another manifest now references the objects the chunk body names, so a reaper deletes only the chunk. The broker's sub-lineage migration and segment fold write it. It is a separate key so that a plain tombstone written later for the same chunk cannot overwrite it. Both bodies are the 8-byte schedule timestamp. `tombstone_seqs` lists the chunks with either marker; `moved_tombstone_seqs` and `moved_tombstone_ts` read the MOVED ones. `reap` and `purge_all` delete both kinds. `_LOG_START` and `_CATALOG` are single objects: the first write uses `If-None-Match: *` and later writes use `If-Match`.

A process-wide reader-writer lock in `komira_async`'s reactor C shim (`src/komira_async/reactor/_posix_shim.c`) wraps the manifest's composite operations. The read verbs (`read_head` and its variants, `read_chunk`, `read_dedup_sentinel`, the tombstone reads, `read_log_start`, `read_catalog_sidecar`) take it shared. `rewrite_chunk_body`, `schedule_for_delete_at`, `reap`, `purge_all`, `advance_log_start` and `cas_catalog_sidecar` take it exclusive. `append` and `append_idempotent` take neither. A test can switch the lock off with `komira_cas_gate_set_disabled`; production never does.

### How is an append made exactly-once?

`append_idempotent` protects against a phantom failure, where a commit lands but the call raises, and against two processes appending for the same producer. It first applies two fences without writing: a producer epoch below the registered one returns `FENCED`, and a lease epoch below the current one returns `LEASE_FENCED`. It then claims a `DedupSentinel` keyed by `(producer_id, first_seq)` with a create-if-absent write, and runs the ordinary append. `_append_idempotent_inner` handles the two failures differently:

- **The claim returns 412.** Another writer holds the claim, so `_resolve_existing_sentinel` reads it and leaves it in place. An absent sentinel returns `RETRYABLE`. A committed sentinel returns `DUPLICATE` with the sentinel's own offsets, without a scan. Otherwise it scans the tail for a chunk carrying the same `(producer_id, first_seq)`: a match returns `DUPLICATE`, and no match returns `RETRYABLE`. Any other claim error is re-raised.
- **The append raises.** It scans the tail. A match returns `COMMITTED` with the recorded offsets. No match deletes its own claim and re-raises the append's error; it does not return `RETRYABLE`.

Marking the sentinel committed after a win is off by default (`_FINALIZE_ON_HOT_PATH = False`); the tail scan recovers the offset without it.

### What other primitives are built on the manifest?

- `CoalescingWindow` (`coalescing_window.mojo`) buffers items in memory and flushes them under a size, count or linger policy (`FlushPolicy`, `evaluate`). It drives one flush at a time, as a start-and-poll state machine over an `AsyncCasStore`, and items offered during a flush wait for the next one.
- `compact_once` (`compact_window.mojo`) runs the shared compaction envelope over a `CompactionSource`: plan a range, fold it into one durable object, advance a watermark, and retire the folded inputs, clamped so that a crash between materializing and advancing never frees an input twice. A lost watermark race leaves a harmless redundant object and retires nothing.
- `ShardedLineage` (`sharded_lineage.mojo`) is the domain-neutral shard layer: it mints writer shard ids, discovers live shards, pins a cross-shard snapshot and plans one dense offset assignment. `SubLineageBaseFold` (`sublineage_base_fold.mojo`) folds shard chunks into a dense `_base` manifest, and `sublineage_shard_keys.mojo` holds the shard-id and prefix helpers.
- `object_store_reachable` (`store_readiness.mojo`) is the readiness check for services that keep state in a bucket: one delimiter listing under `STORE_READINESS_PROBE_PREFIX`. It never raises; any error returns false.

### Where is the shuffle?

The object-store shuffle (map, seal, claim, reduce, retire) is the package `komira_shuffle`, which depends on this one and is not depended on by it. It uses only this library's public surface: `CasManifestStore` and its `RetryPolicy`, the `ConditionalWriteStore` conformers, `Path`, `WritePrecondition`, and `is_precondition` in `cas_manifest.mojo`, the public spelling of the lost-write check.

## Why is it built this way?

### Why is conditional write a refining trait rather than part of ObjectStore?

**Decision.** Writes live on `ConditionalWriteStore`, which refines `ObjectStore`.

**Because.** The comment on `ConditionalWriteStore` in `store.mojo` records that adding a verb to `ObjectStore` would break every conformer, since traits there carry no default method bodies. A separate comment block above `trait CloneableConditionalWriteStore` gives the same reason for that trait: adding `clone()` to `ConditionalWriteStore` would break conformers such as the non-shared in-memory store.

**Alternatives weighed.**

- Add the verbs to `ObjectStore`: every conformer would have to implement them.

**Revisit if.** Traits gain default method bodies.

### Why is the version handle an opaque string?

**Decision.** The version handle is an opaque string: the caller never parses it, reads it from `ObjectMeta.etag`, and passes it back as the `if_match` argument.

**Because.** The `ConditionalWriteStore` docstring says to leave `version` opaque and not assume an S3 etag shape at the trait boundary, because other clouds condition on an integer generation or their own version id.

**Alternatives weighed.**

- Assume the S3 etag shape at the trait boundary: other clouds version an object differently.

**Revisit if.** A backend's version cannot round-trip through a string.

### Why is the manifest _HEAD only a hint?

**Decision.** The create-if-absent write of each chunk decides order, and `_HEAD` may lag the true tail by up to 64 chunks.

**Because.** The comment on `_HEAD_ADVANCE_DEFER_CADENCE` records that `_HEAD` is a recovery cache that listing rebuilds. Deferring its write keeps the common acknowledged append at 2 synchronous operations instead of 3. The same comment bounds the lag so a cold reader does not always pay a full listing. The `_LocalHeadCache` comment records that a stale cache costs at most one lost attempt and cannot commit a wrong offset, because the chunk create still decides.

**Alternatives weighed.**

- Advance `_HEAD` with `If-Match` on every append: one more synchronous write per acknowledged append. The cold path still does this; only warm-cache appends defer.

**Revisit if.** Listing becomes too slow for cold readers at the lineage sizes in use.

### Why is the presign TTL capped at one hour and refused rather than clamped?

**Decision.** `check_presign_ttl` raises for a TTL above 3600 seconds or below 1.

**Because.** The docstring of `PRESIGN_MAX_TTL_SECONDS` records that a presigned URL is a bearer capability that cannot be revoked, so its TTL is its only revocation. The docstring of `check_presign_ttl` records that clamping was rejected: a caller that asked for 24 hours and silently got 1 would retry against a URL it believes is still valid.

**Alternatives weighed.**

- The cloud maximum (seven days on GCS): a leaked URL stays usable for a week.
- Clamping to the cap: turns a refused mint into a flaky transfer.

**Revisit if.** A transfer legitimately needs more than an hour on one URL.

### Why does readiness list a prefix instead of reading an object?

**Decision.** `object_store_reachable` issues one delimiter listing under a sentinel prefix.

**Because.** The header of `store_readiness.mojo` records that a listing separates "bucket absent or unauthorized" (an error) from "prefix empty" (a success), which a `head` of a missing object does not.

**Alternatives weighed.**

- `head` on a known object: a missing object and a missing bucket look alike.

**Revisit if.** A backend's listing succeeds without permission to read.

## What must always hold?

- **One creator per key.** Of concurrent create-if-absent writes to one key, exactly one succeeds. Enforced for manifest chunk slots by `test_cas_manifest_concurrent_offline.mojo`, which races 1, 2, 4, 8 and 16 OS threads appending to one manifest over `SharedInMemoryConditionalStore` and asserts one winner per chunk sequence. The sequential tests `test_contended_slot_one_winner` (`test_cas_manifest_property.mojo`) and `test_create_if_absent_then_412` (`test_local_fs_conditional_store.mojo`) check that a second create on an existing key raises a precondition error.
- **Gapless manifest.** Successive appends take consecutive chunk sequences and round-trip their bodies verbatim. Enforced by `test_sequential_appends_are_gapless` and `test_body_round_trips_verbatim`.
- **Absence is proved, not guessed.** `_is_not_found` in `cas_manifest.mojo` accepts only `StoreError[NOT_FOUND]`, `status=404`, `not_found`, `NotFound` or `NoSuchKey`, never a bare `404`, because chunk keys contain digits. Enforced by `test_cas_manifest_absence_is_anchored.mojo`.

## Where is the code?

| File | Holds | Key types and functions |
|---|---|---|
| `src/komira_objectstore/store.mojo` | the store traits | `ObjectStore`, `ConditionalWriteStore`, `CloneableConditionalWriteStore`, `AsyncCasStore`, `RangeFetchStore` |
| `src/komira_objectstore/types.mojo` | value types and error classes | `ObjectMeta`, `WritePrecondition`, `StoreError`, `CoalescePolicy` |
| `src/komira_objectstore/path.mojo`, `objectstore_uri.mojo` | key normalization, URI parsing | `Path`, `parse` |
| `src/komira_objectstore/cas_manifest.mojo` | the CAS manifest | `MetadataStore`, `CasManifestStore`, `RetryPolicy`, `AsyncManifestAppendOp` |
| `src/komira_objectstore/*_conditional_store.mojo`, `shared_in_memory_*_store.mojo` | local and in-memory conformers | `LocalFsConditionalStore`, `DelimiterFaithfulConditionalStore` |
| `src/komira_objectstore/coalescing_window.mojo`, `compact_window.mojo` | batching and compaction | `CoalescingWindow`, `compact_once` |
| `src/komira_objectstore/sharded_lineage.mojo`, `sublineage_*.mojo` | sharded lineages | `ShardedLineage`, `SubLineageBaseFold` |
| `src/komira_objectstore/presign.mojo`, `store_readiness.mojo` | presign trait, readiness | `ObjectUrlSigner`, `object_store_reachable` |

Entry points:

- **Public API:** `ConditionalWriteStore` in `store.mojo`, with a conformer from the table above; `CasManifestStore` for an append-only lineage.
- **Execution starts at:** `CasManifestStore.append` in `cas_manifest.mojo` for a write.

## How is it tested?

The library welds all 16 files in `src/komira_objectstore/tests/` through `test_srcs`, so building it runs them. Run: `./buck2 build //src/komira_objectstore:komira_objectstore`.

| Tests | Cover |
|---|---|
| `test_path_uri`, `test_coalesce`, `test_objectstore_bytes_non_ascii` | paths and URIs, range coalescing, non-ASCII keys |
| `test_cas_manifest_*`, `test_slow_cas_store_start_412_abi` | the CAS manifest (property, concurrent, stale head, recovery, absence), the start-and-poll 412 path |
| `test_local_fs_*`, `test_delimiter_listing_byte_faithful` | local-directory and delimiter-faithful stores, listing |
| `test_coalescing_window`, `test_compact_window` | `CoalescingWindow` and `compact_once` |
| `test_sharded_lineage_kernel`, `test_sublineage_base_fold` | sharded lineages and the dense `_base` fold |

Not tested here: the cloud conformers of `ConditionalWriteStore`, which belong to the cloud store libraries.

## What are its limits and open questions?

- **Limit: the precondition check can misread a key.** `_is_precondition` in `cas_manifest.mojo` still matches a bare `412`, so an unrelated error about a key containing `412` reads as a lost race. Its neighbour `_is_not_found`'s docstring records this as deliberately left for a separate change. The manifest uses it, and so does the shuffle's claim in `komira_shuffle` (through the public `is_precondition`).
- **Limit: a local-directory `If-Match` is not atomic across processes.** It reads, compares and renames; the shuffle's claim uses create-only writes to avoid that window.
- **Limit: listing semantics differ by conformer** (see [which conformer to use](#which-object-store-conformer-should-a-test-use)).
- **Limit: unused surface.** `RangeFetchStore` and `ObjectStoreHttpStub` have no conformer in this library, `plan_coalesce` has no caller outside its test, and `RequestCore` has no user inside the library.
- **Limit: stale header comments.** The `komira_objectstore` package docstring says the byte-fetch methods live with the HTTP-backed conformers, and the retry comment on `RetryPolicy.broker_contention` says 28 retries where the code uses 40.
- **Open question:** whether the process-wide manifest lock is still needed: the header of `cas_manifest.mojo` ties it to an allocator corruption under contended appends, and `append` already runs without it.
