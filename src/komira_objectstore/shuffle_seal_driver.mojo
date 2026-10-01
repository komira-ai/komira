# =============================================================================
# komira_objectstore/shuffle_seal_driver.mojo
#   The DRIVER-JOIN seal writer + the seal-block reader (the completion seal
#   and the SOLE read barrier).
# =============================================================================
#
# `seal_step(...)` is the driver-join writer:
#   1. Read `_entries` AUTHORITATIVELY (read_head_authoritative — NOT the cached
#      HEAD, because the seal is a correctness consumer).
#   2. Scan `[log_start, head]`, decode each chunk via `decode_shuffle_entry`,
#      SET-INSERT its producer_id -> `committed` (a replayed producer that landed
#      a duplicate `_entries` entry collapses to ONE member — EXACT-SET,
#      EACH-ONCE).
#   3. Verify `committed == expected` as SETS. A missing producer (torn map
#      phase) -> RAISE, do NOT seal.
#   4. Build the LIFTED dense read plan from each producer's dense index.
#   5. `append_idempotent(encode_step_complete(seal), 1, SEAL_WRITER, 0,
#      step_id, step_id, 0)` on the `_seal` prefix — exactly-once under driver
#      retry/replay (DECISION (b), shuffle_seal.mojo).
#
# `read_seal(...)` is the seal-block read the reduce path uses (read,
# sole-read-barrier):
#   * Block on absence (bounded park-and-retry) until the seal chunk is present.
#   * Decode + RE-VERIFY `committed == expected` as sets; fail loud on
#     `committed ⊊ expected` (covers a corrupt/truncated seal).
#
# SOLE-READ-BARRIER discipline: `read_seal` and the
# `_entries` `CasManifestStore` construction are MODULE-PRIVATE here (the `_`
# prefix + the public surface). No raw entries-read API is exposed — the only
# reduce-facing read entry point will be the next step's `shuffle_source`'s
# `SOURCE_SHUFFLE_READ`, which internally calls `read_seal`. The reduce path can
# NOT read the `_entries` manifest tail directly.
#
# Pointer discipline: ZERO UnsafePointer. The driver constructs CasManifestStore
# handles over CLONED backend stores (sharing the same backing —
# CAS-on-S3). heap-reuse N/A (transient values + by-value store handles, no
# wildcard origins).
# =============================================================================

from komira_objectstore.cas_manifest import (
    CasManifestStore,
    IDEMPOTENT_COMMITTED,
    IDEMPOTENT_DUPLICATE,
    RetryPolicy,
)
from komira_objectstore.store import CloneableConditionalWriteStore
from komira_objectstore.shuffle_entry import (
    ShuffleEntry,
    PartitionSlot,
    decode_shuffle_entry,
)
from komira_objectstore.shuffle_seal import (
    StepComplete,
    SEAL_WRITER,
    SEAL_INDEX_LIFTED,
    encode_step_complete,
    decode_step_complete,
    sorted_unique_i64,
    i64_sets_equal,
    i64_set_contains_all,
)


# -----------------------------------------------------------------------------
# Prefix derivation — the three object families root at `{shuffle_id}/{step_id}/`.
# `_entries` and `_seal` are sibling manifest prefixes.
# -----------------------------------------------------------------------------


def entries_prefix(shuffle_id: Int64, step_id: Int64) -> String:
    return String(shuffle_id) + "/" + String(step_id) + "/_entries"


def seal_prefix(shuffle_id: Int64, step_id: Int64) -> String:
    return String(shuffle_id) + "/" + String(step_id) + "/_seal"


# -----------------------------------------------------------------------------
# MODULE-PRIVATE manifest constructors.
# These are NOT part of the reduce-facing surface. The reduce path reads ONLY
# through `read_seal` (and, in the next step, `SOURCE_SHUFFLE_READ`).
# -----------------------------------------------------------------------------


def _entries_manifest[
    S: CloneableConditionalWriteStore
](store: S, shuffle_id: Int64, step_id: Int64) raises -> CasManifestStore[S]:
    # SAFETY: a CLONED handle shares the same backing — the `_entries`
    # manifest reads the same chunks every producer appended.
    return CasManifestStore[S](
        store.clone(), entries_prefix(shuffle_id, step_id), RetryPolicy.default()
    )


def _seal_manifest[
    S: CloneableConditionalWriteStore
](store: S, shuffle_id: Int64, step_id: Int64) raises -> CasManifestStore[S]:
    return CasManifestStore[S](
        store.clone(), seal_prefix(shuffle_id, step_id), RetryPolicy.default()
    )


# -----------------------------------------------------------------------------
# The driver-join scan: build `committed_producers` (deduped) + the per-producer
# dense read plan, by scanning `_entries` AUTHORITATIVELY.
# -----------------------------------------------------------------------------


struct _ScanResult(Movable, Deinitable):
    """The result of scanning `_entries` at the driver join: the deduped
    committed-producer set + the per-producer entries (in scan order) for the
    LIFTED read plan."""

    var committed: List[Int64]  # SORTED-UNIQUE (the set-normal form)
    var entries: List[ShuffleEntry]  # one per DISTINCT producer (first-seen)
    var chunk_count: Int64  # the authoritative head chunk count scanned

    def __init__(out self, var committed: List[Int64], var entries: List[ShuffleEntry], chunk_count: Int64):
        self.committed = committed^
        self.entries = entries^
        self.chunk_count = chunk_count


def _scan_entries[
    S: CloneableConditionalWriteStore
](entries: CasManifestStore[S]) raises -> _ScanResult:
    """Scan `[0, head]` of `_entries` AUTHORITATIVELY. Decode
    each chunk's `ShuffleEntry`, SET-INSERT producer_id into `committed`, and
    keep the FIRST-SEEN entry per distinct producer (a replay's duplicate entry
    is deduped away — the read plan uses the canonical content, which is
    idempotent-identical for a deterministic replay).

    SCAN WINDOW: this scans `[0, head]` and ASSUMES `log_start == 0` — there
    is NO within-epoch retention / GC of `_entries` (the retention reaper
    reclaims WHOLE epochs), so chunk 0 is always live. A within-epoch trim
    would require seeding the floor from `read_log_start` instead of the
    literal 0 so the scan does not walk reclaimed/absent chunks below the live
    log start."""
    var head = entries.read_head_authoritative()
    var top = head.chunk_seq  # highest committed chunk seq (-1 = empty)
    var raw_pids = List[Int64]()
    var seen = List[Int64]()
    var decoded = List[ShuffleEntry]()
    var seq = Int64(0)
    while seq <= top:
        # `read_chunk` already strips the manifest chunk envelope and returns
        # the consumer body (the ShuffleEntry bytes) directly.
        var body = entries.read_chunk(seq)
        var entry = decode_shuffle_entry(body)
        raw_pids.append(entry.producer_id)
        # first-seen-wins for the read-plan entry (dedup the replay duplicate)
        var present = False
        for i in range(len(seen)):
            if seen[i] == entry.producer_id:
                present = True
                break
        if not present:
            seen.append(entry.producer_id)
            decoded.append(entry^)
        seq += Int64(1)
    var committed = sorted_unique_i64(raw_pids)
    return _ScanResult(committed^, decoded^, top + Int64(1))


def _build_lifted_seal(
    shuffle_id: Int64,
    step_id: Int64,
    partition_count: Int64,
    expected_sorted: List[Int64],
    committed_sorted: List[Int64],
    entries: List[ShuffleEntry],
) raises -> StepComplete:
    """Build a LIFTED `StepComplete` from the scanned entries.

    The dense read plan is built in `committed_sorted` order (deterministic) so
    the encoded seal is byte-identical for a deterministic replay (DECISION (b)).
    Each producer contributes EXACTLY R dense (offset,len,row_count) triples; a
    producer entry with fewer than R slots is a torn `.seg` -> RAISE."""
    var r = Int(partition_count)
    var rp_pids = List[Int64]()
    var rp_keys = List[String]()
    var rp_index = List[Int64]()
    for ci in range(len(committed_sorted)):
        var pid = committed_sorted[ci]
        # find this producer's entry
        var found = False
        for ei in range(len(entries)):
            ref e = entries[ei]
            if e.producer_id == pid:
                if len(e.slots) != r:
                    raise Error(
                        "shuffle_seal_driver: producer "
                        + String(pid)
                        + " has "
                        + String(len(e.slots))
                        + " dense slots, expected R="
                        + String(r)
                        + " (torn .seg)"
                    )
                rp_pids.append(pid)
                rp_keys.append(e.object_key.copy())
                for p in range(r):
                    ref s = e.slots[p]
                    rp_index.append(s.offset)
                    rp_index.append(s.length)
                    rp_index.append(s.row_count)
                found = True
                break
        if not found:
            raise Error(
                "shuffle_seal_driver: committed producer "
                + String(pid)
                + " has no scanned entry (internal invariant violation)"
            )
    return StepComplete(
        shuffle_id,
        step_id,
        partition_count,
        SEAL_INDEX_LIFTED,
        expected_sorted.copy(),
        committed_sorted.copy(),
        rp_pids^,
        rp_keys^,
        rp_index^,
        Int64(0),  # entries_floor (LIFTED: unused; TRAILER_FALLBACK carries it)
        Int64(0),  # entries_ceiling
    )


# =============================================================================
# PUBLIC: seal_step — the driver-join writer.
# =============================================================================


def seal_step[
    S: CloneableConditionalWriteStore
](
    mut store: S,
    shuffle_id: Int64,
    step_id: Int64,
    partition_count: Int64,
    expected_producers: List[Int64],
) raises -> StepComplete:
    """Write the `StepComplete` seal at the driver join (driver-join
    writer). Returns the sealed `StepComplete` (its `committed_producers` is the
    deduped set actually committed).

    Raises if `committed ⊊ expected` (a missing producer — torn map phase). On a
    re-drive, `append_idempotent`'s `DedupSentinel` returns DUPLICATE and we
    return the (recomputed, byte-identical) seal — exactly-once seal-write
    (DECISION (b)).
    """
    var expected_sorted = sorted_unique_i64(expected_producers)
    var entries = _entries_manifest(store, shuffle_id, step_id)
    var scan = _scan_entries(entries)

    # step 3: verify committed == expected as SETS; a missing producer
    # is a torn map phase -> RAISE, do NOT seal.
    if not i64_set_contains_all(scan.committed, expected_sorted):
        raise Error(
            "shuffle_seal_driver: torn map phase — committed producer set is a"
            " strict subset of expected (missing producer). NOT sealing."
        )
    if not i64_sets_equal(scan.committed, expected_sorted):
        # committed has a producer not in expected — an over-set is also a torn
        # plan (an unexpected producer committed). Fail loud (fail-loud
        # on any mismatch).
        raise Error(
            "shuffle_seal_driver: committed producer set != expected set"
            " (unexpected producer committed). NOT sealing."
        )

    var seal = _build_lifted_seal(
        shuffle_id,
        step_id,
        partition_count,
        expected_sorted,
        scan.committed,
        scan.entries,
    )

    var seal_store = _seal_manifest(store, shuffle_id, step_id)

    # step 5 / DECISION (b) — IDEMPOTENT seal-write, substrate-honest
    # form. The `_seal` prefix is a SINGLE-SLOT store: a present chunk_seq >= 0
    # IS the seal. On a re-drive (the same driver, or a recovering driver) the
    # seal already exists -> return the EXISTING decoded seal, do NOT re-append.
    # This is the "rely on the sentinel happy path" intent, realized against the
    # real substrate: `append_idempotent`'s recovery-to-DUPLICATE requires either
    # `_FINALIZE_ON_HOT_PATH` (OFF by default) OR a body whose
    # `_body_matches_producer_batch` tail-scan can match (which rejects our
    # negative SEAL_WRITER and would need the broker producer trailer
    # embedded — explicitly forbidden by DECISION (b), no cross-package
    # coupling). So a staged-then-re-driven append returns RETRYABLE, NOT
    # DUPLICATE. We therefore do the single-slot pre-check ourselves: the seal's
    # presence is the idempotency oracle. The driver-join is single-writer-per-
    # step, so this is race-free
    # for the common path; `append_idempotent`'s create-CAS LP still arbitrates a
    # genuine concurrent double-drive (the loser sees the present seal on its
    # re-read). A re-driven step recomputes the byte-identical seal from the same
    # durable `_entries` (DECISION (b) determinism), so returning the existing
    # decoded seal is correct.
    var pre = seal_store.read_head_authoritative()
    if pre.chunk_seq >= Int64(0):
        var existing_body = seal_store.read_chunk(pre.chunk_seq)
        return decode_step_complete(existing_body)

    # Seal absent -> append it. append_idempotent under (SEAL_WRITER, step_id),
    # producer_epoch=0, registered_epoch=0 => never fenced; first_seq ==
    # last_seq == step_id. COMMITTED = we wrote it. A RETRYABLE here means a
    # concurrent driver won the create-CAS between our pre-check and our claim
    # (its chunk may still be staged) -> re-read the seal slot; if present,
    # return it (the concurrent driver sealed it). FENCED cannot occur (never
    # fenced). DUPLICATE cannot occur on a fresh slot but is also success.
    var body = encode_step_complete(seal)
    var res = seal_store.append_idempotent(
        body^,
        Int64(1),  # record_count = 1 (one seal record)
        SEAL_WRITER,
        Int64(0),  # producer_epoch
        step_id,  # first_seq
        step_id,  # last_seq
        Int64(0),  # registered_epoch (never fenced)
    )
    if res.outcome == IDEMPOTENT_COMMITTED or res.outcome == IDEMPOTENT_DUPLICATE:
        return seal^
    # NOTE: the DEFENSIVE arbiter of a genuine concurrent double-drive is the
    # create-CAS If-None-Match linearization point INSIDE append_idempotent (the
    # store-level conditional create), NOT the `pre.chunk_seq >= 0` presence
    # pre-check above. The pre-check is the fast happy path (a re-drive that sees
    # an already-sealed slot); the create-CAS LP is what makes two drivers racing
    # an ABSENT slot resolve to exactly one winner (the loser 412s -> RETRYABLE
    # -> re-reads the winner's seal below).
    # RETRYABLE (a concurrent driver claimed the slot): re-read the seal.
    var post = seal_store.read_head_authoritative()
    if post.chunk_seq >= Int64(0):
        var raced_body = seal_store.read_chunk(post.chunk_seq)
        return decode_step_complete(raced_body)
    raise Error(
        "shuffle_seal_driver: seal append returned RETRYABLE and no seal chunk"
        " is present (the concurrent claimant is mid-append; re-drive seal_step)."
    )


# =============================================================================
# MODULE-PRIVATE: read_seal — the seal-block read (read / sole
# barrier). NOT exposed as a reduce-facing API; the next step's
# SOURCE_SHUFFLE_READ calls this internally. Named with the `read_seal` public
# spelling per the dispatch, but kept off the raw-entries-read surface (there is
# NO entries-read function exported from this module).
# =============================================================================


def read_seal[
    S: CloneableConditionalWriteStore
](
    store: S,
    shuffle_id: Int64,
    step_id: Int64,
    expected_producers: List[Int64],
    max_park_iters: Int = 64,
) raises -> StepComplete:
    """Block-on-absence read of the seal. Bounded park-and-retry
    until the seal chunk is present; then decode + RE-VERIFY `committed ==
    expected` as sets (fail loud on `committed ⊊ expected` — a corrupt/truncated
    seal). Raises if the seal does not appear within `max_park_iters` (the
    bounded park — there is no timer wheel here; a real park substrate belongs
    with the reduce-facing source).

    `expected_producers` is the PLAN-FIXED producer set (the same set the DRIVER
    sealed `seal_step` with). The re-verify compares the seal's committed set
    against THIS argument, so a caller MUST pass the identical plan-fixed set the
    driver used; passing a different set would spuriously raise (or mask a
    partial seal). It is the planner's invariant — not something this function
    can infer — that the reduce side's `expected_producers` == the driver's.

    SOLE-READ-BARRIER: this is the ONLY read path; there is NO
    entries-read API on this module's surface.
    """
    var expected_sorted = sorted_unique_i64(expected_producers)
    var seal_store = _seal_manifest(store, shuffle_id, step_id)
    var it = 0
    while it < max_park_iters:
        var head = seal_store.read_head_authoritative()
        if head.chunk_seq >= Int64(0):
            # seal present — read the top chunk (DECISION (b): byte-identical
            # duplicates are correct; the top is canonical).
            # `read_chunk` returns the seal body directly (envelope stripped).
            var body = seal_store.read_chunk(head.chunk_seq)
            var seal = decode_step_complete(body)
            # RE-VERIFY defensively: a present seal means
            # the driver verified set-equality before writing, but re-check to
            # convert a corrupt/truncated seal into a loud error.
            var committed_sorted = sorted_unique_i64(seal.committed_producers)
            if not i64_set_contains_all(committed_sorted, expected_sorted):
                raise Error(
                    "shuffle_seal_driver: read_seal — committed ⊊ expected"
                    " (corrupt/partial seal). Refusing to aggregate a partial"
                    " set."
                )
            if not i64_sets_equal(committed_sorted, expected_sorted):
                raise Error(
                    "shuffle_seal_driver: read_seal — committed set != expected"
                    " set. Refusing to aggregate."
                )
            return seal^
        it += 1
    raise Error(
        "shuffle_seal_driver: read_seal — seal absent after "
        + String(max_park_iters)
        + " park iterations (step not closed)."
    )
