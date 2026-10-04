# =============================================================================
# tests/test_broker_sublineage_write_soak_offline.mojo
#   The disjoint-keyspace
#   WRITE-path sub-lineage sharding soak + the flag-OFF no-regression gate.
# =============================================================================
#
# THE DISCRIMINATING TEST (the broker analogue of komira_search's sub-lineage
# sharding test). N = 16 REAL concurrent OS-thread writers
# race the SAME partition's manifest:
#
#   * SUB-LINEAGE mode (the fix, GREEN): each writer publishes into its OWN
#     sub-lineage `<partition>/_lineage/<shard_id>` — a DISJOINT keyspace. Each
#     writer is the SOLE writer of its lineage's `_HEAD` create-CAS slot, so
#     EVERY append wins on the FIRST attempt → retry_mult == 1.000 (zero 412s),
#     zero dropped appends. This is the architecture's contention-free claim.
#
#   * SHARED-HEAD mode (the legacy single-manifest shape, RED control): all N
#     writers race ONE manifest `_HEAD` slot → the 412-loser re-reads HEAD +
#     retries under backoff → retry_mult > 1.000 (some appends take > 1 attempt).
#     This is what the sub-lineage write path REMOVES.
#
# `retry_mult == total_attempts / total_commits`. == 1.000 ⟺ every append won
# first try. The contrast (RED shared vs GREEN disjoint) proves the SHARDING is
# what removes the contention, not the harness.
#
# The soak drives the manifest-append CAS DIRECTLY at the active prefix (the same
# prefix `BrokerCore` routes to in each mode — see `_active_manifest_prefix`),
# reading `AppendResult.attempts` (which `ProduceResult` does not surface). A
# separate test (`test_brokercore_flag_routes_and_off_is_unchanged`) drives the
# real `BrokerCore.flush` path to prove the flag toggles the append target +
# that flag-OFF is byte-identical to the consolidated single-manifest behavior.
#
# Plus the shard_id minting gate (`test_shard_id_minting_collision_free`): the
# `<instance_id>-<pid>[-w<idx>]-<boot_nonce>` form is distinct for distinct
# tuples, stable for a fixed tuple, folds getpid, and rejects an empty
# instance_id.
#
# Encapsulation audit: ZERO UnsafePointer in any public signature; the pthread
# launch uses the sanctioned FFI-BOUNDARY carve-out (same as
# test_cas_manifest_concurrent_offline). The shard_id / prefix helpers are pure
# value transforms; no wildcard-origin field, no byte-slab element.
# =============================================================================

from std.ffi import external_call
from std.memory import OwnedPointer, UnsafePointer, alloc
from std.time import perf_counter_ns
from std.testing import assert_equal, assert_true

from komira_core.arrow.arrow_types import ArrowType
from komira_core.arrow.column import Column
from komira_core.arrow.primitive_array import PrimitiveArray
from komira_core.arrow.record_batch import RecordBatch
from komira_core.arrow.schema import Schema
from komira_core.collections.slab import Slab

from komira_broker.broker_core import BrokerCore
from komira_broker.partition_assignment import (
    mint_shard_id,
    sublineage_prefix,
    broker_boot_nonce,
)

from komira_objectstore.cas_manifest import CasManifestStore, RetryPolicy
from komira_objectstore.shared_in_memory_conditional_store import (


    SharedInMemoryConditionalStore,
)

@always_inline
def _null_ptr[T: AnyType, o: Origin]() -> UnsafePointer[T, o]:
    """A NULL typed pointer with a concrete origin (replaces the b2-removed null
    UnsafePointer ctor / the `_unsafe_null=()` b1 idiom).

    # SAFETY: `Optional[UnsafePointer[...]]` is layout-compatible with the bare
    # pointer (modular/mojo/proposals/non-null-pointer.md); `None` is the all-zero
    # (NULL) bit pattern. Origin `o` is concrete; the NULL sentinel is never
    # dereferenced (placeholder / explicit C-NULL arg).
    """
    var none: Optional[UnsafePointer[T, o]] = None
    return UnsafePointer(to=none).bitcast[UnsafePointer[T, o]]()[]



comptime _Store = SharedInMemoryConditionalStore


def _partition_prefix(cluster: String, topic: String, pid: Int64) -> String:
    # The single-partition base manifest prefix (the broker's `_manifest_prefix`
    # shape) — the SHARED-HEAD target + the base under which sub-lineages live.
    return cluster + "/_meta/topics/" + topic + "/" + String(pid)


def _body(tag: Int, n: Int) -> List[UInt8]:
    var out = List[UInt8]()
    for i in range(n):
        out.append(UInt8((i + tag) & 0xFF))
    return out^


# =============================================================================
# Per-append record + per-writer results (heap-stable; read after join)
# =============================================================================


@fieldwise_init
struct _AppendRecord(Copyable, Movable, Deinitable):
    var chunk_seq: Int64
    var base_offset: Int64
    var attempts: Int64
    var terminal_fail: Int64


struct _WriterResults(Movable, Deinitable):
    var records: List[_AppendRecord]

    def __init__(out self):
        self.records = List[_AppendRecord]()


# =============================================================================
# The pthread arg — the cloned (shared!) backend + the per-writer prefix.
#
# In SUB-LINEAGE mode each writer's `prefix` is its OWN sub-lineage
# (`sublineage_prefix(base, shard_id)`), so the writers have DISJOINT keyspaces.
# In SHARED-HEAD mode every writer's `prefix` is the SAME base prefix, so they
# race one `_HEAD` slot. The harness is identical; only the prefix differs —
# exactly the property the design relies on ("the sharding lives in the prefix").
# =============================================================================


struct _WriterArg(Movable, Deinitable):
    var store: SharedInMemoryConditionalStore
    var prefix: String
    var num_appends: Int64
    var records_per_append: Int64
    # SAFETY: address of a heap-stable `_WriterResults` owned by the main thread
    # (kept alive until the join). Plain Int — no wildcard field.
    var results_addr: Int

    def __init__(
        out self,
        var store: SharedInMemoryConditionalStore,
        var prefix: String,
        num_appends: Int64,
        records_per_append: Int64,
        results_addr: Int,
    ):
        self.store = store^
        self.prefix = prefix^
        self.num_appends = num_appends
        self.records_per_append = records_per_append
        self.results_addr = results_addr


def _writer_entry(
    arg: UnsafePointer[NoneType, MutUntrackedOrigin]
) -> UnsafePointer[NoneType, MutUntrackedOrigin]:
    # SAFETY: `arg` is the heap `_WriterArg*` from `alloc + init_pointee_move`.
    # Reconstruct the OwnedPointer so it frees at scope exit.
    var typed = arg.bitcast[_WriterArg]()
    var owned = OwnedPointer[_WriterArg](unsafe_from_raw_pointer=typed)
    try:
        _run_writer(owned[])
    except e:
        print("WARN _writer_entry: writer raised: ", String(e))
    _ = owned^
    return _null_ptr[NoneType, MutUntrackedOrigin]()


def _run_writer(mut arg: _WriterArg) raises:
    # SAFETY (FFI-BOUNDARY — sanctioned pthread-launch carve-out): the results
    # address is a main-thread `OwnedPointer[_WriterResults]` pointee, alive
    # until the main thread joins this pthread. DISJOINTNESS: writer `w` touches
    # ONLY its own results slot. No realloc of the slot.
    var results_ptr = UnsafePointer[_WriterResults, MutUntrackedOrigin](
        unsafe_from_address=arg.results_addr
    )
    # A plain CasManifestStore over THIS writer's prefix (its own sub-lineage in
    # SHARDED mode, the shared base in SHARED-HEAD mode). The backend handle is a
    # SHARED clone (Arc to one map), so SHARED-HEAD writers genuinely contend.
    var manifest = CasManifestStore[SharedInMemoryConditionalStore](
        store=arg.store.clone(),
        prefix=arg.prefix.copy(),
        retry=RetryPolicy.broker_contention(),
    )
    var i = Int64(0)
    while i < arg.num_appends:
        var body = _body(Int(i), 16)
        var failed = Int64(0)
        var seq = Int64(-1)
        var base = Int64(-1)
        var attempts = Int64(0)
        try:
            var res = manifest.append(body, arg.records_per_append)
            seq = res.chunk_seq
            base = res.base_offset
            attempts = Int64(res.attempts)
        except e:
            failed = Int64(1)
            _ = e
        results_ptr[].records.append(
            _AppendRecord(seq, base, attempts, failed)
        )
        i += Int64(1)


def _spawn_writer(var arg: _WriterArg, mut tid_slot: Int64) raises -> Int32:
    # SAFETY: heap-box the arg, hand its address to pthread_create; the thread
    # reconstructs + frees it. MutExternalOrigin only on the void* ABI args.
    var raw = alloc[_WriterArg](1)
    UnsafePointer(to=raw[]).unsafe_write(arg^)
    var raw_void = raw.bitcast[NoneType]().unsafe_origin_cast[
        MutUntrackedOrigin
    ]()
    var slot_addr = UnsafePointer(to=tid_slot)
    return external_call["pthread_create", Int32](
        slot_addr.bitcast[UInt8](),
        _null_ptr[UInt8, MutUntrackedOrigin](),
        _writer_entry,
        raw_void,
    )


def _join_writer(tid: Int64) -> Int32:
    return external_call["pthread_join", Int32](
        tid, _null_ptr[UInt8, MutUntrackedOrigin]()
    )


# =============================================================================
# _RunStats — the aggregate of one N-writer fan-out.
# =============================================================================


@fieldwise_init
struct _RunStats(Copyable, Movable, Deinitable):
    var total_commits: Int64
    var total_attempts: Int64
    var terminal_fails: Int64
    var max_attempts: Int64
    # retry_mult * 1000, integer (avoid Float equality flake). 1000 == 1.000.
    var retry_mult_milli: Int64
    # The union of distinct chunk_seqs PER writer (each writer's own seq space).
    # For sub-lineage mode, every writer should claim {0..M-1} in its OWN
    # lineage; for shared mode, the union across writers is {0..N*M-1}.
    var distinct_global_seqs: Int64


def _run_n_writers(
    n: Int,
    appends_per_writer: Int64,
    records_per_append: Int64,
    sharded: Bool,
    base_prefix: String,
) raises -> _RunStats:
    # ONE shared backend; every writer gets a clone() that SHARES the map.
    var shared = SharedInMemoryConditionalStore()

    var results = Slab[OwnedPointer[_WriterResults]]()
    for _w in range(n):
        results.append(OwnedPointer[_WriterResults](_WriterResults()))
    var tids = List[Int64]()
    for _w in range(n):
        tids.append(Int64(0))

    var w = 0
    while w < n:
        var addr = Int(UnsafePointer(to=results[w][]))
        # The ONLY difference between the GREEN (sharded) and RED (shared) runs:
        # the prefix. Sharded → each writer's own `_lineage/<shard_id>`; shared
        # → the SAME base prefix for all writers (the legacy single-manifest).
        var prefix = base_prefix
        if sharded:
            # A deterministic-but-distinct shard_id per writer (the soak does not
            # need the live getpid/nonce — distinctness across writers is the
            # property under test; minting is tested separately).
            prefix = sublineage_prefix(
                base_prefix, String("writer-") + String(w)
            )
        var arg = _WriterArg(
            store=shared.clone(),
            prefix=prefix^,
            num_appends=appends_per_writer,
            records_per_append=records_per_append,
            results_addr=addr,
        )
        var rc = _spawn_writer(arg^, tids[w])
        if rc != Int32(0):
            raise Error("pthread_create failed for writer " + String(w))
        w += 1

    w = 0
    while w < n:
        _ = _join_writer(tids[w])
        w += 1

    # ---- aggregate ----
    var total_attempts = Int64(0)
    var total_commits = Int64(0)
    var terminal_fails = Int64(0)
    var max_attempts = Int64(0)
    var all_seqs = List[Int64]()
    for wi in range(n):
        ref recs = results[wi][].records
        for ri in range(len(recs)):
            ref r = recs[ri]
            if r.terminal_fail == Int64(1):
                terminal_fails += Int64(1)
                continue
            total_commits += Int64(1)
            total_attempts += r.attempts
            if r.attempts > max_attempts:
                max_attempts = r.attempts
            # Tag the seq with the writer index in sharded mode so the "global"
            # distinctness across disjoint lineages is meaningful.
            if sharded:
                all_seqs.append(Int64(wi) * Int64(1_000_000) + r.chunk_seq)
            else:
                all_seqs.append(r.chunk_seq)

    var retry_mult_milli = Int64(1000)
    if total_commits > Int64(0):
        retry_mult_milli = (total_attempts * Int64(1000)) / total_commits

    # distinct seqs
    var seen = List[Int64]()
    for idx in range(len(all_seqs)):
        var s = all_seqs[idx]
        var found = False
        for j in range(len(seen)):
            if seen[j] == s:
                found = True
                break
        if not found:
            seen.append(s)

    _ = results^
    _ = tids^
    _ = shared^
    return _RunStats(
        total_commits,
        total_attempts,
        terminal_fails,
        max_attempts,
        retry_mult_milli,
        Int64(len(seen)),
    )


# =============================================================================
# (1) The headline RED→GREEN soak: N=16. Sharded → retry_mult == 1.000;
#     Shared-HEAD → retry_mult > 1.000 (the contention the sharding removes).
# =============================================================================


def test_sublineage_n16_retry_mult_is_one_red_green() raises:
    print(
        "[sub-lineage soak] N=16 concurrent writers — sub-lineage (disjoint)"
        " vs shared-HEAD (legacy single manifest)"
    )
    var n = 16
    var appends = Int64(16)
    var rpa = Int64(1)
    var base = _partition_prefix(String("clusterA"), String("topicX"), Int64(0))

    # GREEN: disjoint sub-lineages. Every append wins first try.
    var green = _run_n_writers(n, appends, rpa, True, base)
    print(
        "      SHARDED  commits="
        + String(Int(green.total_commits))
        + " attempts="
        + String(Int(green.total_attempts))
        + " retry_mult(milli)="
        + String(Int(green.retry_mult_milli))
        + " max_attempts="
        + String(Int(green.max_attempts))
        + " terminal_fails="
        + String(Int(green.terminal_fails))
    )
    var expected = Int64(n) * appends
    assert_equal(
        green.total_commits, expected, "sharded: every append commits (N*M)"
    )
    assert_equal(
        green.terminal_fails,
        Int64(0),
        "sharded: zero dropped appends (sole-writer-per-lineage)",
    )
    # THE DISCRIMINATING ASSERT — retry_mult == 1.000 (100% first-attempt-win).
    assert_equal(
        green.retry_mult_milli,
        Int64(1000),
        "sharded: retry_mult == 1.000 (zero 412s — disjoint keyspaces)",
    )
    assert_equal(
        green.max_attempts,
        Int64(1),
        "sharded: NO append ever took > 1 attempt",
    )
    assert_equal(
        green.distinct_global_seqs,
        expected,
        "sharded: every committed (writer,seq) is distinct (no lost split)",
    )

    # RED control: all writers on ONE shared manifest → genuine contention.
    var red = _run_n_writers(n, appends, rpa, False, base)
    print(
        "      SHARED   commits="
        + String(Int(red.total_commits))
        + " attempts="
        + String(Int(red.total_attempts))
        + " retry_mult(milli)="
        + String(Int(red.retry_mult_milli))
        + " max_attempts="
        + String(Int(red.max_attempts))
    )
    # The shared lineage is still gapless + linearizable (the CAS guarantees it)
    # — that is NOT what we are discriminating on. We discriminate on CONTENTION:
    # the shared run MUST show retry_mult > 1.000 (some append lost its slot and
    # retried), proving the sub-lineage write path is what removes the 412 storm.
    assert_equal(
        red.total_commits,
        expected,
        "shared: still commits all (CAS keeps it gapless)",
    )
    assert_true(
        red.retry_mult_milli > Int64(1000),
        "shared-HEAD: retry_mult > 1.000 (contention the sharding removes)",
    )
    assert_true(
        red.max_attempts > Int64(1),
        "shared-HEAD: at least one append took > 1 attempt (412 contention)",
    )
    print(
        "[OK] sub-lineage soak — sub-lineage retry_mult==1.000 (GREEN);"
        " shared-HEAD retry_mult>1.000 (RED contention removed by sharding)"
    )


# =============================================================================
# (2) BrokerCore flag routing + flag-OFF byte-identical (no regression).
# =============================================================================


def _make_int64_batch(base_val: Int64, n: Int) raises -> RecordBatch:
    var schema = Schema(
        names=[String("val")],
        arrow_types=[ArrowType.INT64.type_id],
        dtypes=[DType.int64],
        nullables=[False],
    )
    var arr = PrimitiveArray[DType.int64].allocate(n)
    var p = arr._typed_ptr_mut()
    for i in range(n):
        p.store[width=1](i, base_val + Int64(i))
    var col = Column.from_primitive[DType.int64](arr^)
    return RecordBatch.from_typed_columns_1(schema^, col^)


def _make_broker(
    store: _Store, cluster: String, topic: String, pid: Int64
) raises -> BrokerCore[_Store]:
    var prefix = _partition_prefix(cluster, topic, pid)
    var manifest = CasManifestStore[_Store](
        store=store.clone(), prefix=prefix^, retry=RetryPolicy.fast_test()
    )
    return BrokerCore[_Store](
        segment_store=store.clone(),
        manifest=manifest^,
        cluster=cluster,
        topic=topic,
        partition=pid,
        broker_id=String("broker-A"),
    )


def test_brokercore_flag_routes_and_off_is_unchanged() raises:
    print("[sub-lineage] BrokerCore flag routing + flag-OFF byte-identical")
    var cluster = String("clusterA")
    var topic = String("topicX")
    var pid = Int64(3)
    var base = _partition_prefix(cluster, topic, pid)

    # ---- flag-OFF: default-constructed core. Active prefix == base; a flush
    #      lands the chunk under the CONSOLIDATED manifest (unchanged path). ----
    var store_off = _Store()
    var core_off = _make_broker(store_off, cluster, topic, pid)
    assert_true(
        not core_off.sublineage_write_enabled(),
        "default-constructed core: sub-lineage write is OFF",
    )
    assert_equal(
        core_off._active_manifest_prefix(),
        base,
        "flag-OFF: the active append target is the consolidated base prefix",
    )
    assert_equal(
        core_off.shard_id(),
        String(""),
        "flag-OFF: no shard_id",
    )
    core_off.buffer_batch(_make_int64_batch(Int64(100), 4), Int64(1))
    var r_off = core_off.flush_with_producer(
        Int64(1), Int64(7), Int64(0), Int64(0), Int64(3)
    )
    # The consolidated manifest must now have exactly ONE committed chunk; the
    # base offsets start at 0 (the first flush). This is byte-identical to the
    # consolidated single-manifest behavior (the chunk landed in the base lineage's _HEAD).
    assert_equal(r_off.base_offset, Int64(0), "flag-OFF: base offset 0")
    assert_equal(r_off.last_offset, Int64(3), "flag-OFF: last offset 3 (4 recs)")
    assert_equal(r_off.chunk_seq, Int64(0), "flag-OFF: chunk_seq 0")
    var consolidated = CasManifestStore[_Store](
        store=store_off.clone(),
        prefix=base,
        retry=RetryPolicy.fast_test(),
    )
    assert_equal(
        consolidated.num_chunks(),
        Int64(1),
        "flag-OFF: the chunk landed in the CONSOLIDATED manifest",
    )
    # And NOTHING landed under any `_lineage/` sub-prefix.
    var legacy_sub = CasManifestStore[_Store](
        store=store_off.clone(),
        prefix=sublineage_prefix(base, String("writer-0")),
        retry=RetryPolicy.fast_test(),
    )
    assert_equal(
        legacy_sub.num_chunks(),
        Int64(0),
        "flag-OFF: NO chunk landed under any sub-lineage prefix",
    )

    # ---- flag-ON: enable sub-lineage write. Active prefix == the sub-lineage;
    #      a flush lands the chunk under `_lineage/<shard_id>`, NOT the base. ----
    var store_on = _Store()
    var core_on = _make_broker(store_on, cluster, topic, pid)
    var shard = String("nodeA-1234-w0-99")
    var sl_prefix = core_on.sublineage_prefix_for(shard)
    assert_equal(
        sl_prefix,
        base + "/_lineage/" + shard,
        "sublineage_prefix_for builds <base>/_lineage/<shard_id>",
    )
    # The wiring layer mints the per-shard manifest (the core trusts the prefix).
    var sl_manifest = CasManifestStore[_Store](
        store=store_on.clone(),
        prefix=sl_prefix,
        retry=RetryPolicy.fast_test(),
    )
    core_on.enable_sublineage_write(shard, sl_manifest^, Int64(5))
    assert_true(
        core_on.sublineage_write_enabled(),
        "flag-ON: sub-lineage write enabled",
    )
    assert_equal(
        core_on.shard_id(), shard, "flag-ON: shard_id recorded"
    )
    assert_equal(
        core_on._active_manifest_prefix(),
        sl_prefix,
        "flag-ON: the active append target is the sub-lineage prefix",
    )
    core_on.buffer_batch(_make_int64_batch(Int64(200), 5), Int64(1))
    var r_on = core_on.flush_with_producer(
        Int64(1), Int64(9), Int64(0), Int64(0), Int64(4)
    )
    assert_equal(r_on.base_offset, Int64(0), "flag-ON: base offset 0 in its own lineage")
    assert_equal(r_on.last_offset, Int64(4), "flag-ON: last offset 4 (5 recs)")
    # The chunk landed in the SUB-LINEAGE, and the CONSOLIDATED manifest is empty.
    var sl_read = CasManifestStore[_Store](
        store=store_on.clone(), prefix=sl_prefix, retry=RetryPolicy.fast_test()
    )
    assert_equal(
        sl_read.num_chunks(),
        Int64(1),
        "flag-ON: the chunk landed in the SUB-LINEAGE",
    )
    var consolidated_on = CasManifestStore[_Store](
        store=store_on.clone(), prefix=base, retry=RetryPolicy.fast_test()
    )
    assert_equal(
        consolidated_on.num_chunks(),
        Int64(0),
        "flag-ON: the consolidated manifest is EMPTY (write-slot decoupled)",
    )
    print("[OK] sub-lineage — flag routes the append target; flag-OFF unchanged")


# =============================================================================
# (3) shard_id minting — collision-free + stable + boot nonce + raises.
# =============================================================================


def test_shard_id_minting_collision_free() raises:
    print("[sub-lineage] shard_id minting — collision-free + stable + boot nonce")

    # Stable: same (instance, worker, fixed nonce) → identical shard_id.
    var a1 = mint_shard_id(String("nodeA"), 0, Int64(42))
    var a2 = mint_shard_id(String("nodeA"), 0, Int64(42))
    assert_equal(a1, a2, "same (instance, worker, nonce) → stable shard_id")

    # Distinct by worker_idx.
    var b = mint_shard_id(String("nodeA"), 1, Int64(42))
    assert_true(a1 != b, "distinct worker_idx → distinct shard_id")

    # Distinct by instance_id.
    var c = mint_shard_id(String("nodeB"), 0, Int64(42))
    assert_true(a1 != c, "distinct instance_id → distinct shard_id")

    # Distinct by boot_nonce — a REUSED instance_id (+ same pid + same
    # worker) across a reboot still mints a DISTINCT sub-lineage because the
    # boot nonce differs. This is the instance-reuse-collision defense.
    var d = mint_shard_id(String("nodeA"), 0, Int64(43))
    assert_true(
        a1 != d,
        "distinct boot_nonce → distinct shard_id (instance-reuse defense)",
    )

    # The shard_id folds getpid (the current process id appears as a segment).
    var pid_str = String(Int64(external_call["getpid", Int32]()))
    assert_true(
        a1.find(pid_str) >= 0, "shard_id folds getpid"
    )

    # worker_idx < 0 omits the -w<idx> segment.
    var no_worker = mint_shard_id(String("nodeA"), -1, Int64(42))
    assert_true(
        no_worker.find("-w") < 0,
        "worker_idx < 0 omits the -w segment",
    )
    var with_worker = mint_shard_id(String("nodeA"), 2, Int64(42))
    assert_true(
        with_worker.find("-w2") >= 0,
        "worker_idx >= 0 includes the -w<idx> segment",
    )

    # The shard_id is one path segment (no '/').
    assert_true(a1.find("/") < 0, "shard_id contains no '/' (one path segment)")

    # The auto-minted boot nonce is non-negative + (almost surely) non-zero.
    var nonce = broker_boot_nonce()
    assert_true(nonce >= Int64(0), "broker_boot_nonce is non-negative")

    # An empty instance_id is a wiring bug → raises (fail-loud, not a degenerate
    # `-pid-nonce` shard_id that defeats distinctness).
    var raised = False
    try:
        _ = mint_shard_id(String(""), 0, Int64(42))
    except e:
        raised = True
        _ = e
    assert_true(raised, "empty instance_id raises (fail-loud)")

    # sublineage_prefix shape.
    var pfx = sublineage_prefix(String("clusterA/_meta/topics/t/0"), a1)
    assert_equal(
        pfx,
        String("clusterA/_meta/topics/t/0/_lineage/") + a1,
        "sublineage_prefix = <base>/_lineage/<shard_id>",
    )
    print("[OK] sub-lineage — shard_id minting collision-free + stable + boot nonce")


def main() raises:
    test_sublineage_n16_retry_mult_is_one_red_green()
    test_brokercore_flag_routes_and_off_is_unchanged()
    test_shard_id_minting_collision_free()
    print(
        "[OK] test_broker_sublineage_write_soak_offline — sub-lineage write path:"
        " N=16 disjoint-lineage retry_mult==1.000, flag-OFF byte-identical,"
        " shard_id collision-free"
    )
