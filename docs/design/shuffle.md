# Shuffle: moving rows between producers and reducers through an object store

## What is it for, and what is out of scope?

`komira_shuffle` (`src/komira_shuffle`) moves rows from a set of map-side producers to a variable number of reduce-side workers through a bucket, with no server between them. A producer writes its output once, durably; a seal says the map phase is complete; reducers pull partitions by claiming them, so the partitions are processed exactly once however many reducers run. It builds on `komira_objectstore` (the CAS manifest, the conditional-write stores and `Path`); that package does not depend on this one.

Out of scope:

- The object-store traits, the CAS manifest and the stores themselves: see the object-store design doc (`object_store.md`).
- Reclaiming a claim held by a reducer that died. The claim is single-winner only; there is no lease.

## How does it work?

The shuffle moves rows from producers to reducers through a bucket, with keys under `{shuffle_id}/{step_id}/`:

1. **Map.** `sink_shuffle_write` (`sink.mojo`) assigns each row a partition with `HashPartitioner` (`partitioner.mojo`): FNV-1a-64 of the key bytes, then the high `log2(R)` bits (`radix_partition` in `radix.mojo`). R must be a power of two. It writes one `{producer_id}.seg` object holding every partition's bytes and a trailer with a `PartitionSlot` (offset, length, row count) for every partition, empty ones included. It then records a `ShuffleEntry` in the `_entries` manifest with `append_idempotent`, so a replayed producer adds no second entry.
2. **Seal.** `seal_step` (`seal_driver.mojo`), the one writer at the driver join, reads `_entries` with `read_head_authoritative`, collects the committed producers as a set, so a replayed producer counts once, and raises unless that set equals the expected set. If a seal is already present it returns that one; otherwise it writes a `StepComplete` seal to `_seal` with `append_idempotent`.
3. **Claim.** `claim_partition` (`claim.mojo`) creates `_claims/{partition_id}` with `If-None-Match: *` and returns false if another reducer created it first.
4. **Reduce.** `read_shuffle_partition` (`source.mojo`) waits (bounded by `max_park_iters`) for the seal, raises if the committed set is short of the expected set, skips zero-length slices, and fetches each remaining slice with `get_range`. It is the only public read path; nothing exposes `_entries`.
5. **Retire.** `reclaim_floor` (`retention.mojo`) is the minimum consumer cursor and raises on an empty cursor set. `reap_epoch` and `reap_epochs_below` delete what lies below it.

`codec.mojo` holds the little-endian integer and length-prefixed string encoders the entry and seal formats use.

## What must always hold?

- **A claim fails closed, with one hole.** `claim_partition` returns false on a precondition failure and re-raises anything else. Enforced by `test_claim_partition_reraises_on_non_eexist_failure`. The hole: it classifies with `_is_precondition`, which matches a bare `412` (see limits).
- **A reducer never under-reads.** `read_shuffle_partition` returns only after the seal lists every expected producer. Enforced by `test_phase_a_seal_blocks_on_absence_and_missing_set` and `test_phase_a_idempotent_replay_no_double_read`.
- **Retention keeps what a consumer still needs.** Enforced by `test_lagging_consumer_pins_floor` and `test_reap_below_floor_retains_at_and_above` (`tests/test_shuffle_retention_reaper.mojo`).

## Where is the code?

| Path | Holds | Key names |
|---|---|---|
| `src/komira_shuffle/sink.mojo`, `partitioner.mojo`, `radix.mojo`, `segment.mojo` | the map side | `sink_shuffle_write`, `HashPartitioner`, `radix_partition`, `SegWriter` |
| `src/komira_shuffle/entry.mojo`, `seal.mojo`, `seal_driver.mojo` | the manifest entry and the seal | `ShuffleEntry`, `StepComplete`, `seal_step`, `read_seal` |
| `src/komira_shuffle/claim.mojo`, `source.mojo` | the reduce side | `claim_partition`, `read_shuffle_partition` |
| `src/komira_shuffle/retention.mojo` | the reaper | `reclaim_floor`, `reap_epoch`, `reap_epochs_below` |
| `src/komira_shuffle/codec.mojo` | little-endian encoders | `put_i64_le`, `get_i64_le` |

- **Execution starts at:** `sink_shuffle_write` for a producer, `seal_step` at the driver join, `read_shuffle_partition` for a reducer.

## How is it tested?

The library welds its 5 files in `src/komira_shuffle/tests/` through `test_srcs`, so building it runs them. Run: `./buck2 build //src/komira_shuffle:komira_shuffle`.

| Test | Covers |
|---|---|
| `test_shuffle_claim_fail_closed` | the claim fails closed: a lost race returns false, anything else re-raises |
| `test_shuffle_seal_phase_a` | the seal as the read barrier, producer-set verification, replay |
| `test_shuffle_seal_codec_driver` | the entry and seal codecs, the driver |
| `test_shuffle_continuous_epoch_seal` | continuous epochs |
| `test_shuffle_retention_reaper` | the reclaim floor and the reaper |

## What are its limits and open questions?

- **Limit: the precondition check can misread a key.** `_is_precondition` in `cas_manifest.mojo` still matches a bare `412`, so an unrelated error about a key containing `412` reads as a lost race. The same limit applies to the claim here: it classifies with `is_precondition`, which wraps it. Its neighbour `_is_not_found`'s docstring records this as deliberately left for a separate change. A claim key is `{shuffle_id}/{step_id}/_claims/{partition_id}`, and a store whose HTTP-status errors name the key can return a 403 or 5xx on a claim whose key contains `412`, which returns false so that partition can be silently skipped.
- **Limit: a local-directory `If-Match` is not atomic across processes.** The claim uses create-only writes to avoid that window.
- **Limit: no lease.** A reducer that dies while holding a claim leaves its partition claimed and unprocessed.
