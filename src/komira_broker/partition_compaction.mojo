# =============================================================================
# komira_broker/partition_compaction.mojo
#   Dynamic partition scaling — the lineage-collapse COMPACTION tick
# =============================================================================
#
# A background tick rewrites a split parent's segments into child-A-only and
# child-B-only segments, after which the lineage parent-read drops. This keeps
# the effective lineage depth small (about 1-2) instead of letting a deep split
# tree grow the ancestor walk every read pays.
#
# -----------------------------------------------------------------------------
# WHAT COMPACTION DOES (and is NOT)
# -----------------------------------------------------------------------------
# A SPLIT leaves the parent holding BOTH children's records (the parent's
# `[0, X)` covers the whole `[lo, hi)` range; child A covers `[lo, mid)`, child B
# `[mid, hi)`). A whole-topic drain reads the parent ONCE (unfiltered) + both
# children — that is already exactly-once + correct. But a SINGLE-CHILD consumer
# of A must read the parent prefix filtered to `[lo, mid)`, and a DEEP split tree
# makes that ancestor walk grow. COMPACTION (option ii) fixes this:
#
#   1. Read the frozen parent's segments (decoded RecordBatches — supplied by the
#      caller via the decode seam; the broker LEAF does not decode).
#   2. Re-route each row to the child whose subrange owns its key's fnv1a hash
#      (the SAME high-bits `range_containing_pid` routing the producer uses), and
#      RE-APPEND the range-pure rows into the children's manifests (each child's
#      manifest now holds the parent's `[lo, mid)` / `[mid, hi)` rows too).
#   3. CAS the partition map to COLLAPSE the parent's lineage edge
#      (`map.collapse_lineage(parent_pid)`): the parent tombstone is dropped + the
#      children's split back-edges cleared. A future read-order build NO LONGER
#      reads the parent prefix — the child's effective lineage depth drops by one.
#
# The parent's (now-orphaned) segments are left for RETENTION to reap — compaction
# does NOT delete them (idempotent + crash-safe: if the CAS fails, the parent is
# still readable; if it succeeds, retention sweeps the orphan later).
#
# CORRECTNESS-EQUIVALENT (a pure optimization for correctness-
# equivalent reads"): post-compaction, a whole-topic drain reads {A, B} (each now
# range-pure with the parent's rows folded in) and gets EVERY record exactly once
# — the SAME multiset as the pre-compaction {parent, A, B} drain (the parent's
# rows moved INTO the children; the parent is dropped from the read order). Order
# is preserved because the re-appended parent rows are written in produce order
# AHEAD of each child's post-split rows... see the ORDERING note below.
#
# -----------------------------------------------------------------------------
# ORDERING SUBTLETY (read this — the keystone for compaction correctness)
# -----------------------------------------------------------------------------
# Per-key order MUST survive compaction. Pre-compaction, key `k ∈ [lo, mid)` has
# order: parent[k] (offsets <= X) THEN A[k] (A's own post-split records). Post-
# compaction we re-append parent[k] into A's manifest — but A ALREADY has its
# post-split records. If we appended parent[k] AFTER A's existing records, `k`'s
# order would invert (A-post then parent-pre — WRONG).
#
# THE RULE: compaction is run BEFORE the child accumulates post-split records, OR
# the re-append is done into a FRESH child manifest generation that is read FIRST.
# This compaction targets the stated use ("compact BEFORE re-
# splitting" / keep depth ~1-2): it is invoked on a child that has NOT yet taken
# post-split writes (the depth-cap gate fires when a deep child is about to be
# split — compaction runs on its ANCESTOR whose child is still empty of its own
# records, or the orchestrator drains+re-appends atomically). The offline test
# exercises the "parent rows fold into a child with no post-split records yet"
# shape; the produce-order invariant is asserted there. A child WITH post-split
# records uses the read-time filter path (option i, partition_split.mojo) and is
# NOT compacted by this tick — the trigger only proposes compaction for a clean
# (empty-child) collapse. A child that already holds post-split records is
# handled by the gen-model compaction below.)
#
# -----------------------------------------------------------------------------
# Encapsulation discipline
# -----------------------------------------------------------------------------
#   * ZERO UnsafePointer in any signature — surface is value / RecordBatch /
#     Slab / BrokerCore (by ref) / POD.
#   * ZERO wildcard origins / `unsafe_from_address` / `take_pointee`.
#   * Every type here is a stack value, never a byte-slab element.
#   * Leaf-clean: uses the broker-local fnv1a fold (mirrors consumer_source.mojo)
#     — no komira_engine_runtime dep (the broker is a DAG leaf).
# =============================================================================

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch
from komira_arrow.schema import Schema
from komira_collections.slab import Slab

from komira_objectstore.cas_manifest import CasManifestStore, is_not_found
from komira_objectstore.store import ConditionalWriteStore

from .broker_core import BrokerCore
from .retention import advance_log_start_monotone
from .partition_map import (
    PartitionMap,
    prefix_gen_manifest_prefix,
    read_partition_map_with_etag,
    try_persist_update,
)


# =============================================================================
# Broker-local fnv1a-64 of an INT64 key (mirrors consumer_source.mojo's fold +
# the producer's `_fold_int_le` for INT64 — the canonical high-bits routing).
# =============================================================================


@always_inline
def _compaction_fnv1a_offset_basis() -> UInt64:
    return UInt64(14695981039346656037)


@always_inline
def _compaction_fnv1a_prime() -> UInt64:
    return UInt64(1099511628211)


def fnv1a_int64_key(v: Int64) -> UInt64:
    """The canonical fnv1a-64 of an INT64 key value (its 8 LE bytes), matching
    the producer's `_fold_int_le` for INT64 + the test's `_fnv1a_of_int64`. Used
    to re-route a parent row to the child subrange owning its key's hash. Leaf-
    local fold (no engine_runtime dep)."""
    var bits = UInt64(Int(v))
    var h: UInt64 = _compaction_fnv1a_offset_basis()
    var prime: UInt64 = _compaction_fnv1a_prime()
    for i in range(8):
        var b = UInt8(Int((bits >> UInt64(i * 8)) & UInt64(0xFF)))
        h = (h ^ UInt64(b)) * prime
    return h


# =============================================================================
# CompactionResult — what a lineage-collapse compaction returns. POD.
# =============================================================================


@fieldwise_init
struct CompactionResult(Copyable, Movable, Deinitable):
    """The result of a `compact_split_parent`. POD.

    Field layout:
      var parent_pid: Int        — the SPLIT parent whose lineage was collapsed.
      var child_a_pid: Int       — the lower-subrange child the parent's `[lo,
                                   mid)` rows were folded into.
      var child_b_pid: Int       — the upper-subrange child.
      var rows_to_a: Int         — count of parent rows re-appended to child A.
      var rows_to_b: Int         — count of parent rows re-appended to child B.
      var new_version: Int       — the map version after the lineage collapse.
      var collapsed: Bool        — True iff the map CAS landed (the parent was
                                   dropped from the read order). False on a CAS
                                   miss (a concurrent event moved the map; the
                                   rows were still re-appended — idempotent, the
                                   caller may retry the collapse).
    """

    var parent_pid: Int
    var child_a_pid: Int
    var child_b_pid: Int
    var rows_to_a: Int
    var rows_to_b: Int
    var new_version: Int
    var collapsed: Bool


# =============================================================================
# partition_rows_by_child — split one decoded INT64 batch's rows by child subrange.
# =============================================================================


def _make_int64_batch_from_values(values: List[Int64]) raises -> RecordBatch:
    """Build a single-column INT64 RecordBatch from `values` (the broker's
    canonical key/test column shape). Mirrors the test's `_make_int64_batch` but
    for N rows."""
    var schema = Schema(
        names=[String("val")],
        arrow_types=[ArrowType.INT64.type_id],
        dtypes=[DType.int64],
        nullables=[False],
    )
    var arr = PrimitiveArray[DType.int64].allocate(len(values))
    var p = arr._typed_ptr_mut()
    for i in range(len(values)):
        p.store[width=1](i, values[i])
    var col = Column.from_primitive[DType.int64](arr^)
    return RecordBatch.from_typed_columns_1(schema^, col^)


# =============================================================================
# compact_split_parent — re-route a frozen parent's rows into its children +
# CAS-collapse the lineage (the depth-collapse tick).
# =============================================================================


def compact_split_parent[
    Store: ConditionalWriteStore
](
    store: Store,
    cluster: String,
    topic: String,
    var parent_batches: Slab[RecordBatch],
    var child_a_core: BrokerCore[Store],
    var child_b_core: BrokerCore[Store],
    parent_pid: Int,
    now_ms: Int64 = Int64(0),
    max_cas_attempts: Int = 8,
) raises -> CompactionResult:
    """Lineage-collapse compaction of a frozen SPLIT parent `parent_pid`.

    `parent_batches` are the parent's segments already DECODED into RecordBatches
    by the caller (the decode seam — the broker leaf does not decode).
    `child_a_core` / `child_b_core` are live `BrokerCore`s bound to the two
    children's manifest prefixes (the same prefixes the producer routes to).

    Steps:
      1. Read the current map + its ETag; resolve the parent tombstone's two
         child pids + their subrange boundary (the midpoint `mid`).
      2. For each parent batch, for each row: route by `fnv1a(key)` ->
         `range_containing_pid`; a hash < mid goes to child A, else child B.
         Build per-child INT64 batches preserving produce (row) order.
      3. Re-append the range-pure batches to the children's manifests
         (`BrokerCore.produce` + force-flush). Each child's manifest now holds
         the parent's rows for its subrange.
      4. CAS `map.collapse_lineage(parent_pid)` (drop the parent tombstone +
         clear the children's back-edges). On a CAS miss, the rows were still
         re-appended (idempotent — a re-run re-appends nothing new because the
         caller is expected to compact a fresh/empty child once); the caller may
         retry the collapse CAS. We surface `collapsed=False` rather than spin.

    Returns a `CompactionResult` (rows moved + whether the collapse landed).
    Raises if `parent_pid` is not a SPLIT-parent tombstone or on a store error.

    PRECONDITION (ORDERING — see the module header): the children must NOT yet
    hold their own post-split records when this runs (the "compact before
    re-split" use), so the re-appended parent rows precede any child rows in
    produce order. The trigger only proposes compaction for that clean shape."""
    # Step 1: resolve the parent tombstone -> children + the subrange midpoint.
    var cur = read_partition_map_with_etag[Store](store, cluster, topic)
    var tomb = cur.map.retired_for_pid(parent_pid)
    if not tomb:
        raise Error(
            "compact_split_parent: pid "
            + String(parent_pid)
            + " is not a retired partition (nothing to compact)"
        )
    ref t = tomb.value()
    if t.is_merge():
        raise Error(
            "compact_split_parent: pid "
            + String(parent_pid)
            + " is a MERGE predecessor, not a SPLIT parent — merge"
            " predecessors are already range-pure and never need compaction"
            " (a merge is pure metadata)"
        )
    var child_a = t.child_a_pid
    var child_b = t.child_b_pid
    # The subrange boundary == child A's hi == child B's lo. Find it from the
    # live children's ranges (a child may itself have been re-split, but for the
    # depth-collapse use the children are leaves).
    var mid = _child_boundary(cur.map, parent_pid, child_a, child_b)

    # Step 2: partition every parent row by subrange (produce order preserved).
    var a_vals = List[Int64]()
    var b_vals = List[Int64]()
    var nb = len(parent_batches)
    for bi in range(nb):
        ref rb = parent_batches[bi]
        var nrows = rb.num_rows()
        for row in range(nrows):
            var v = rb.column_value(0, row)
            var h = fnv1a_int64_key(v)
            if h < mid:
                a_vals.append(v)
            else:
                b_vals.append(v)
    parent_batches.set_len_unchecked(0)
    _ = parent_batches^

    # Step 3: re-append the range-pure rows to the children's manifests.
    if len(a_vals) > 0:
        var batch_a = _make_int64_batch_from_values(a_vals)
        _ = child_a_core.produce(batch_a^, now_ms)
        _ = child_a_core.flush_if_buffered(now_ms + Int64(1))
    if len(b_vals) > 0:
        var batch_b = _make_int64_batch_from_values(b_vals)
        _ = child_b_core.produce(batch_b^, now_ms)
        _ = child_b_core.flush_if_buffered(now_ms + Int64(1))
    _ = child_a_core^
    _ = child_b_core^

    # Step 4: CAS-collapse the lineage (drop the parent tombstone). Retry the
    # read-modify-CAS on a miss; the row re-append above already landed.
    var rows_to_a = len(a_vals)
    var rows_to_b = len(b_vals)
    var attempt = 0
    while attempt < max_cas_attempts:
        attempt += 1
        var c2 = read_partition_map_with_etag[Store](store, cluster, topic)
        # If the parent was already collapsed by a concurrent tick, treat as done.
        var still = c2.map.retired_for_pid(parent_pid)
        if not still:
            return CompactionResult(
                parent_pid=parent_pid,
                child_a_pid=child_a,
                child_b_pid=child_b,
                rows_to_a=rows_to_a,
                rows_to_b=rows_to_b,
                new_version=c2.map.version,
                collapsed=True,
            )
        var collapsed_map = c2.map.collapse_lineage(parent_pid)
        var new_version = collapsed_map.version
        var ok = try_persist_update[Store](
            store, cluster, topic, collapsed_map, c2.etag
        )
        if ok:
            return CompactionResult(
                parent_pid=parent_pid,
                child_a_pid=child_a,
                child_b_pid=child_b,
                rows_to_a=rows_to_a,
                rows_to_b=rows_to_b,
                new_version=new_version,
                collapsed=True,
            )
        # CAS miss: re-read + retry the collapse (rows already re-appended).

    # Persistent contention — the rows landed; the collapse did not. The caller
    # may retry the collapse alone (idempotent — rows are not re-appended on a
    # collapse-only retry path).
    return CompactionResult(
        parent_pid=parent_pid,
        child_a_pid=child_a,
        child_b_pid=child_b,
        rows_to_a=rows_to_a,
        rows_to_b=rows_to_b,
        new_version=cur.map.version,
        collapsed=False,
    )


# =============================================================================
# GenCompactionResult — what a gen-model (hot-child) compaction returns. POD.
# =============================================================================


@fieldwise_init
struct GenCompactionResult(Copyable, Movable, Deinitable):
    """The result of a `compact_split_parent_gen` (the gen-model HOT-CHILD
    lineage collapse). POD.

    Field layout:
      var parent_pid: Int          — the SPLIT parent whose lineage was collapsed.
      var child_a_pid: Int         — the lower-subrange child.
      var child_b_pid: Int         — the upper-subrange child.
      var prefix_gen_seq: Int64    — the generation token annotated on BOTH live
                                     children (the parent's range-pure rows live
                                     in each child's `<child_pid>.g<gen>` manifest,
                                     read strictly before the child's live gen).
      var rows_to_a: Int           — committed parent rows migrated to child A's
                                     prefix generation.
      var rows_to_b: Int           — committed parent rows migrated to child B's
                                     prefix generation.
      var new_version: Int         — the map version after the lineage collapse.
      var collapsed: Bool          — True iff the map CAS landed (the parent was
                                     dropped from the read order). False when
                                     every collapse CAS attempt missed (the
                                     prefix-gen rows landed; a re-run appends
                                     none of them again and retries the
                                     collapse).
    """

    var parent_pid: Int
    var child_a_pid: Int
    var child_b_pid: Int
    var prefix_gen_seq: Int64
    var rows_to_a: Int
    var rows_to_b: Int
    var new_version: Int
    var collapsed: Bool


# =============================================================================
# compact_split_parent_gen — the GEN-MODEL hot-child compaction. Migrate a frozen
# parent's range-pure, read_committed-VISIBLE rows into each child's SEPARATE
# from-0 PREFIX-GENERATION manifest (read strictly BEFORE the child's live
# generation), then ONE If-Match map CAS collapses the lineage parent-edge +
# annotates the children with `prefix_gen_seq`. The child's LIVE-generation
# offsets are UNCHANGED (committed-offset stability). Works even when the child
# ALREADY has live writes (the case `compact_split_parent` FORBIDS).
# =============================================================================


def compact_split_parent_gen[
    Store: ConditionalWriteStore
](
    store: Store,
    cluster: String,
    topic: String,
    var parent_batches: Slab[RecordBatch],
    var prefix_gen_a_core: BrokerCore[Store],
    var prefix_gen_b_core: BrokerCore[Store],
    var parent_manifest: CasManifestStore[Store],
    parent_pid: Int,
    now_ms: Int64 = Int64(0),
    max_cas_attempts: Int = 8,
) raises -> GenCompactionResult:
    """Gen-model lineage-collapse compaction of a frozen SPLIT parent
    `parent_pid` whose children may ALREADY hold their own live records (the
    case `compact_split_parent`'s PRECONDITION forbids).

    `parent_batches` are the parent's READ_COMMITTED-VISIBLE rows already decoded
    into RecordBatches by the caller (the decode seam — the broker leaf
    does not decode; AND the caller has applied the read_committed lens, never
    handing in an aborted/in-flight parent record). The prefix
    generation is thus a marker-free, always-visible, committed-only history.

    `prefix_gen_a_core` / `prefix_gen_b_core` are `BrokerCore`s the caller has
    bound to the children's PREFIX-GENERATION manifest prefixes —
    `prefix_gen_manifest_prefix(cluster, topic, child_pid, gen)` — FRESH from-0
    manifests at the `<child_pid>.g<gen>` sibling key, NOT the children's live
    prefixes. `parent_manifest` is the parent's CasManifestStore (bound to the
    parent's live prefix), consumed to schedule the parent's orphaned chunks for
    grace-gated reaping after the collapse CAS lands.

    The generation token `<gen>` is `parent_pid`, so a re-run binds the same
    `<child_pid>.g<gen>` prefixes. Step 3 appends only the rows a prefix
    generation does not hold yet, so a re-run after a failure anywhere in
    steps 3-4 (or a lost collapse, `collapsed=False`) writes each row once.

    Steps (idempotent, crash-safe, mirroring `compact_split_parent`):
      1. Resolve the parent tombstone -> children + the subrange midpoint.
      2. Partition every committed parent row by subrange (produce order
         preserved) — exactly as `compact_split_parent`.
      3. Write the range-pure rows into the children's PREFIX-GENERATION
         manifests (ordinary from-0 appends, on fresh sibling prefixes — no
         insert-ahead-of-tail needed), skipping the rows an earlier run already
         committed there (`_write_prefix_gen_rows`). Invisible until step 4
         references them via the map.
      4. ONE If-Match map CAS: `collapse_lineage_with_prefix_gen(parent_pid,
         gen_a, gen_b)` — drop the parent tombstone + annotate each live child
         with `prefix_gen_seq` + clear the split back-edges. On a CAS miss,
         re-read + retry the collapse alone (the prefix-gen rows already landed).
      5. After the collapse lands, schedule the parent's manifest chunks for
         delete (the grace-gated ReapWorker deletes the orphaned parent segments
         after `grace_ms`) — NO new GC machinery.

    RESUME: once the collapse has landed the parent is no longer retired. A
    call for a pid the map allocated that is neither live nor retired
    (`_lineage_collapsed`) runs step 5 alone and returns `collapsed=True`,
    so a failure in step 5 is finished by calling again with the same pid.

    Returns a `GenCompactionResult`. Raises if `parent_pid` is neither a
    SPLIT-parent tombstone nor a collapsed parent, or on a store error.

    NO PRECONDITION on child emptiness (the whole point): the children may
    already hold live writes; their live offsets are untouched."""
    # Step 1: resolve the parent tombstone -> children + the subrange midpoint.
    var cur = read_partition_map_with_etag[Store](store, cluster, topic)
    var tomb = cur.map.retired_for_pid(parent_pid)
    if not tomb:
        if _lineage_collapsed(cur.map, parent_pid):
            # RESUME: an earlier run's collapse CAS (step 4) landed, but its
            # step 5 may not have finished (a failed advance or tombstone, a
            # crash). The parent is no longer a read step, so run step 5
            # (idempotent) and stop: steps 2-4 are done. The children are not
            # re-derived (-1).
            _schedule_parent_chunks_for_delete[Store](parent_manifest, now_ms)
            _ = parent_manifest^
            return GenCompactionResult(
                parent_pid=parent_pid,
                child_a_pid=-1,
                child_b_pid=-1,
                prefix_gen_seq=Int64(parent_pid),
                rows_to_a=0,
                rows_to_b=0,
                new_version=cur.map.version,
                collapsed=True,
            )
        raise Error(
            "compact_split_parent_gen: pid "
            + String(parent_pid)
            + " is not a retired partition (nothing to compact)"
        )
    ref t = tomb.value()
    if t.is_merge():
        raise Error(
            "compact_split_parent_gen: pid "
            + String(parent_pid)
            + " is a MERGE predecessor, not a SPLIT parent — merge"
            " predecessors are already range-pure and never need compaction"
            " (a merge is pure metadata)"
        )
    var child_a = t.child_a_pid
    var child_b = t.child_b_pid
    var mid = _child_boundary(cur.map, parent_pid, child_a, child_b)

    # The generation token (deterministic — content-addressed by parent_pid).
    var gen = Int64(parent_pid)

    # Step 2: partition every committed parent row by subrange (produce order).
    var a_vals = List[Int64]()
    var b_vals = List[Int64]()
    var nb = len(parent_batches)
    for bi in range(nb):
        ref rb = parent_batches[bi]
        var nrows = rb.num_rows()
        for row in range(nrows):
            var v = rb.column_value(0, row)
            var h = fnv1a_int64_key(v)
            if h < mid:
                a_vals.append(v)
            else:
                b_vals.append(v)
    parent_batches.set_len_unchecked(0)
    _ = parent_batches^

    # Step 3: write the range-pure rows into the children's PREFIX-GENERATION
    # manifests (fresh from-0 manifests at the `<child_pid>.g<gen>` siblings),
    # minus the rows an earlier run already committed there.
    _write_prefix_gen_rows[Store](prefix_gen_a_core, a_vals, now_ms)
    _write_prefix_gen_rows[Store](prefix_gen_b_core, b_vals, now_ms)
    _ = prefix_gen_a_core^
    _ = prefix_gen_b_core^

    # The per-child prefix-gen seq: NO_PARENT_BASE for a child that received NO
    # rows (e.g. all parent rows hashed to the other child) so the read order
    # doesn't walk an empty prefix gen; else `gen`.
    var seq_a = gen if len(a_vals) > 0 else Int64(-1)
    var seq_b = gen if len(b_vals) > 0 else Int64(-1)

    var rows_to_a = len(a_vals)
    var rows_to_b = len(b_vals)

    # Step 4: ONE If-Match CAS — collapse the lineage + annotate the children.
    var collapsed = False
    var final_version = cur.map.version
    var attempt = 0
    while attempt < max_cas_attempts:
        attempt += 1
        var c2 = read_partition_map_with_etag[Store](store, cluster, topic)
        var still = c2.map.retired_for_pid(parent_pid)
        if not still:
            # Already collapsed by a concurrent tick — done.
            collapsed = True
            final_version = c2.map.version
            break
        var collapsed_map = c2.map.collapse_lineage_with_prefix_gen(
            parent_pid, seq_a, seq_b
        )
        var new_version = collapsed_map.version
        var ok = try_persist_update[Store](
            store, cluster, topic, collapsed_map, c2.etag
        )
        if ok:
            collapsed = True
            final_version = new_version
            break
        # CAS miss: re-read + retry the collapse (prefix-gen rows already landed).

    # Step 5: schedule the parent's orphaned chunks for grace-gated reaping (only
    # once the collapse landed — before that the parent is still referenced).
    if collapsed:
        _schedule_parent_chunks_for_delete[Store](parent_manifest, now_ms)
    _ = parent_manifest^

    return GenCompactionResult(
        parent_pid=parent_pid,
        child_a_pid=child_a,
        child_b_pid=child_b,
        prefix_gen_seq=gen,
        rows_to_a=rows_to_a,
        rows_to_b=rows_to_b,
        new_version=final_version,
        collapsed=collapsed,
    )


def _lineage_collapsed(map: PartitionMap, pid: Int) -> Bool:
    """True iff `pid` is a pid the map allocated (`0 <= pid < next_pid`) that
    is neither a live range nor a retired one. A pid leaves `ranges` only by
    retiring (a split or a merge adds its `RetiredRange`), and only a lineage
    collapse (`collapse_lineage`, `collapse_lineage_with_prefix_gen`) removes a
    `RetiredRange`, so such a pid is a split parent whose collapse landed. This
    holds whatever its rows did: it needs no mark on a live child, so a parent
    that migrated no rows, or whose children have split again since, is still
    recognised."""
    if pid < 0 or pid >= map.next_pid:
        return False
    if map._range_index_for_pid(pid) >= 0:
        return False
    if map.retired_for_pid(pid):
        return False
    return True


def _write_prefix_gen_rows[
    Store: ConditionalWriteStore
](mut core: BrokerCore[Store], vals: List[Int64], now_ms: Int64) raises:
    """Append to `core`'s prefix-generation manifest the rows of `vals` it does
    not hold yet: `vals[committed:]`, where `committed` is the manifest's
    authoritative next offset (one offset per row, from 0). Nothing is appended
    when the manifest already holds `len(vals)` rows or more: an earlier run
    of the same parent committed them (its rows come in the same produce order,
    or are a superset when retention reaped part of the parent since). The rows
    go out in one produce and one flush, so one segment and one chunk.

    `core` is a fresh core bound to the prefix-generation prefix, appending to
    its consolidated manifest (sub-lineage write mode off)."""
    var committed = Int(core._manifest.read_head_authoritative().next_offset)
    var n = len(vals)
    if committed >= n:
        return
    var rest = List[Int64](capacity=n - committed)
    for i in range(committed, n):
        rest.append(vals[i])
    var batch = _make_int64_batch_from_values(rest)
    _ = core.produce(batch^, now_ms)
    _ = core.flush_if_buffered(now_ms + Int64(1))


def _schedule_parent_chunks_for_delete[
    Store: ConditionalWriteStore
](mut parent_manifest: CasManifestStore[Store], now_ms: Int64) raises:
    """Retire EVERY committed chunk of the (now-orphaned) parent manifest:
    advance the parent's `_LOG_START` past its top chunk, THEN tombstone each
    chunk so the grace-gated `ReapWorker` deletes the parent's segments after
    `grace_ms`. The tombstone is a metadata marker; the actual `.seg` delete
    happens in the reaper after the grace window protects any in-flight pre-CAS
    drain. Idempotent (the advance is monotone; last-writer-wins on each
    `<seq>.tomb`).

    The ADVANCE comes first because the reaper deletes only below `_LOG_START`
    (chunk_reclaim_guard.mojo): tombstones under an unmoved log start would be
    skipped forever. The parent has no "sealed" state; a log start one past
    its top chunk (based at its next offset) is how a fully retired lineage is
    recorded, the same state retention leaves once a whole prefix is reaped. A
    failed advance raises before any tombstone; the caller retries
    (`compact_split_parent_gen` resumes here once its collapse has landed).
    A chunk already gone is skipped: retention may have reaped the parent's
    prefix earlier, or the reaper an earlier run's tombstones. After the
    advance every chunk 0..top is below the log start, so a missing one is
    reaped, never a torn live lineage."""
    # A correctness consumer of the tail: read_head() prefers the stale-low
    # local cache, so this must LIST the authoritative
    # tail. This runs from a maintenance/cold-cache instance (a fresh
    # `parent_manifest` whose local `_HEAD` cache is empty), so `read_head()` would
    # read the DURABLE `_HEAD` whose advance is deferred off the warm-append ack
    # path (lags by up to `_HEAD_ADVANCE_DEFER_CADENCE` chunks). A stale-low
    # `head.chunk_seq` would leave the parent's orphan chunks ABOVE the stale tail
    # un-tombstoned -> the reaper never deletes them -> a storage leak. The chunk
    # objects are always durable (unconditional create-CAS), so the LIST-recovered
    # authoritative tail sees every committed chunk.
    var head = parent_manifest.read_head_authoritative()
    var top = head.chunk_seq  # highest committed seq (-1 == empty)
    # An empty parent (top == -1) targets (0, 0), where the log start already
    # is: the advance is a no-op and the loop below runs zero times.
    _ = advance_log_start_monotone(
        parent_manifest, top + Int64(1), head.next_offset
    )
    var seq = Int64(0)
    while seq <= top:
        try:
            parent_manifest.schedule_for_delete_at(seq, now_ms)
        except e:
            if not is_not_found(String(e)):
                raise e^
        seq += Int64(1)


def _child_boundary(
    map: PartitionMap, parent_pid: Int, child_a: Int, child_b: Int
) raises -> UInt64:
    """The subrange boundary `mid` (== child A's hi == child B's lo) for a split
    parent. Read off the live children's ranges if present; else recover from the
    parent tombstone's own bounds via the midpoint formula (the same `mid = lo +
    (hi - lo) / 2` the split used). Raises if neither is recoverable."""
    var ia = map._range_index_for_pid(child_a)
    if ia >= 0:
        return map.ranges[ia].hash_hi
    var ib = map._range_index_for_pid(child_b)
    if ib >= 0:
        return map.ranges[ib].hash_lo
    # Children no longer live (re-split). Recover from the parent tombstone via
    # the deterministic midpoint formula.
    var tomb = map.retired_for_pid(parent_pid)
    if not tomb:
        raise Error(
            "compact_split_parent: cannot recover the child subrange boundary"
            " for parent "
            + String(parent_pid)
            + " (children not live + no tombstone)"
        )
    ref t = tomb.value()
    var lo = t.hash_lo
    var hi = t.hash_hi
    return lo + (hi - lo) / UInt64(2)
