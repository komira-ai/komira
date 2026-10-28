# =============================================================================
# join_multi_key_parallel -- the parallel composite-key INNER probe over the
# engine's dispatcher, and the merge of the workers' matches.
# =============================================================================
#
# `parallel_multi_key_inner_probe_into` sizes probe morsels with the engine's
# fork grain (or `mk_probe_morsel_rows()`), fans the workers out
# (`join_multi_key_parallel_task`), then concatenates their match lists into the
# caller's two output lists in worker order: a prefix scan gives each worker a
# disjoint destination range and a second fanned wave copies every worker's
# segment into place. The merged lists hold the same pairs as the serial
# `MultiKeyHashJoinBuilder.probe_inner_into`; only their order differs.
# =============================================================================

from std.memory import memcpy, UnsafePointer
from std.sys import num_physical_cores

from komira_async.ops.waker_sink import NoopSink
from komira_async.runtime.local_dispatcher import LocalDispatcher
from komira_async.runtime.parallel_fork_join_shared import (
    parallel_fork_join_shared,
)
from komira_async.runtime.sched_trace import (
    SITE_JOIN_MK_MERGE,
    SITE_JOIN_MULTIKEY,
)
from komira_async_api.shared_chunk_work import SharedChunkWork
from komira_async_api.token import CancellationToken
from komira_collections.slab import Slab
from komira_engine_runtime.fan_out_grain import parallel_fork_grain
from komira_engine_runtime.grain_geometry import grain_geometry_record

from .join_multi_key import MultiKeyColumns, _CHAIN_END
from .join_multi_key_builder import MultiKeyHashJoinBuilder
from .join_multi_key_parallel_task import (
    MultiKeyParallelProbeState,
    MultiKeyParallelProbeTask,
)
from .join_probe_settings import (
    MK_PROBE_RETILE_MIN_ROWS,
    mk_probe_batch_width,
    mk_probe_morsel_rows,
    mk_probe_retile_on,
)


comptime _MK_PARALLEL_THRESHOLD: Int = 100_000
"""Below this many probe rows `execute_multi_key_join_probe` probes serially."""

comptime _ENABLE_MULTI_KEY_PARALLEL_PROBE: Bool = True


struct _MKMergeSrc(Movable, Deinitable):
    """The wave's shared payload: the per-worker source lists, drained out of the
    probe state's Slabs, plus the per-chunk copied counts.
    """

    var build: List[List[Int]]
    var probe: List[List[Int]]
    var copied: List[Int]

    def __init__(
        out self,
        var build: List[List[Int]],
        var probe: List[List[Int]],
        var copied: List[Int],
    ):
        self.build = build^
        self.probe = probe^
        self.copied = copied^


@fieldwise_init
struct _MKMergeWork[o_b: MutOrigin, o_p: MutOrigin](SharedChunkWork):
    """Chunk `c` memcpys worker `c`'s build and probe match segments into the
    caller's output lists at the SAME offset `dst_off[c]`.
    """

    # SAFETY: raw destination pointers with CONCRETE mutable origins pinned to the
    # caller's two output lists. Written only within this module, only inside the
    # disjoint range the prefix scan assigned this chunk, and never escaping.
    var dst_build: UnsafePointer[Int, Self.o_b]
    var dst_probe: UnsafePointer[Int, Self.o_p]

    def process[
        In: Deinitable, P: Movable & Deinitable
    ](
        self, chunk_id: Int, n_chunks: Int, ref input: In, mut payload: P,
    ) raises:
        _ = n_chunks
        # SAFETY: the driver instantiates this with In=List[Int] (the borrowed
        # exclusive prefix scan) and P=_MKMergeSrc at the one dispatch site in
        # `_run_mk_merge_wave` below.
        var ip = UnsafePointer(to=input).bitcast[List[Int]]()
        var pp = UnsafePointer(to=payload).bitcast[_MKMergeSrc]()
        var off = ip[][chunk_id]
        var n = ip[][chunk_id + 1] - off

        var nb = len(pp[].build[chunk_id])
        var np_ = len(pp[].probe[chunk_id])
        if nb != n or np_ != n:
            raise Error(
                "mk_merge: worker "
                + String(chunk_id)
                + " match lists diverged from the prefix scan (build="
                + String(nb)
                + " probe="
                + String(np_)
                + " scan="
                + String(n)
                + ")"
            )

        if n > 0:
            memcpy(
                dest=self.dst_build + off,
                src=pp[].build[chunk_id].unsafe_ptr(),
                count=n,
            )
            memcpy(
                dest=self.dst_probe + off,
                src=pp[].probe[chunk_id].unsafe_ptr(),
                count=n,
            )
        pp[].copied[chunk_id] = n


def _run_mk_merge_wave[
    o_b: MutOrigin, o_p: MutOrigin, disp_o: Origin[mut=True],
](
    dst_build: UnsafePointer[Int, o_b],
    dst_probe: UnsafePointer[Int, o_p],
    imm dst_off: List[Int],
    var src: _MKMergeSrc,
    n_chunks: Int,
    dispatcher_ptr: Pointer[LocalDispatcher[NoopSink], disp_o],
) raises -> _MKMergeSrc:
    """Thin dispatch shim: `o_b` / `o_p` are inferred from the pointer
    arguments (a `List.unsafe_ptr()` carries the origin of the list's buffer,
    which the construction site cannot spell)."""
    var work = _MKMergeWork[o_b, o_p](dst_build, dst_probe)
    return parallel_fork_join_shared[
        _MKMergeWork[o_b, o_p],
        List[Int],
        _MKMergeSrc,
        origin_of(dst_off),
        disp_o,
    ](
        work^,
        dst_off,
        src^,
        n_chunks,
        dispatcher_ptr,
        CancellationToken.never(),
        2,
        0,
        SITE_JOIN_MK_MERGE,
    )


def parallel_multi_key_inner_probe_into(
    mut dispatcher: LocalDispatcher[NoopSink],
    var cancel_token: CancellationToken,
    ref builder: MultiKeyHashJoinBuilder,
    ref probe_keys: MultiKeyColumns,
    mut build_matches: List[Int],
    mut probe_matches: List[Int],
) raises:
    """Parallel inner-join probe that appends to caller-provided output lists.

    The same pairs as `builder.probe_inner_into(probe_keys, ...)`, grouped by
    worker. Raises if the probe key count or lengths disagree. When it raises
    after the probe, both output lists hold only the rows they held on entry.

    Args:
        dispatcher: Caller-owned LocalDispatcher reference.
        cancel_token: Caller-supplied CancellationToken (consumed).
        builder: Pre-built composite-key index (read-only during probe).
        probe_keys: Probe-side N-key bundle (read-only during probe).
        build_matches: Output list for build-side row indices (appended).
        probe_matches: Output list for probe-side row indices (appended).
    """
    var n_keys = builder._num_keys
    if probe_keys.num_keys != n_keys:
        raise Error(
            "parallel_multi_key_inner_probe_into: probe key count "
            + String(probe_keys.num_keys)
            + " != build key count "
            + String(n_keys)
        )
    var num_probe_rows = probe_keys.int_keys.value()[0].length
    for k in range(1, n_keys):
        if probe_keys.int_keys.value()[k].length != num_probe_rows:
            raise Error(
                "parallel_multi_key_inner_probe_into: probe key "
                + String(k)
                + " length "
                + String(probe_keys.int_keys.value()[k].length)
                + " != probe key 0 length "
                + String(num_probe_rows)
            )

    var mask = UInt64(builder._capacity - 1)
    var pool_n = dispatcher.worker_count()
    if pool_n < 1:
        pool_n = 1
    var morsel_size = parallel_fork_grain(num_probe_rows, pool_n)
    var _ms_override = mk_probe_morsel_rows()
    if _ms_override > 0:
        morsel_size = _ms_override
    var num_morsels = (num_probe_rows + morsel_size - 1) // morsel_size
    var _cores = num_physical_cores()
    var num_workers = min(num_morsels, pool_n)
    grain_geometry_record(
        SITE_JOIN_MULTIKEY, num_probe_rows, morsel_size, num_morsels, num_workers
    )

    if (
        _ms_override == 0
        and mk_probe_retile_on()
        and num_workers == _cores
        and num_morsels < 4 * num_workers
    ):
        var target = (num_probe_rows + 4 * num_workers - 1) // (4 * num_workers)
        if target < MK_PROBE_RETILE_MIN_ROWS:
            target = MK_PROBE_RETILE_MIN_ROWS
        if target < morsel_size:
            morsel_size = target
            num_morsels = (num_probe_rows + morsel_size - 1) // morsel_size

    var num_build_rows = builder._num_inserted
    var non_empty_buckets = 0
    var ht_size_ptr = builder._hash_table.unsafe_ptr()
    for s in range(builder._capacity):
        if (ht_size_ptr + s)[] != _CHAIN_END:
            non_empty_buckets += 1
    var est_matches_per_probe = 1
    if non_empty_buckets > 0 and num_build_rows > 0:
        var avg_chain = num_build_rows // non_empty_buckets
        if avg_chain > 0:
            est_matches_per_probe = avg_chain
    var est_total_matches = Int(
        Float64(num_probe_rows) * Float64(est_matches_per_probe) * 1.1
    )
    if est_total_matches < num_probe_rows:
        est_total_matches = num_probe_rows
    var est_per_worker = max(est_total_matches // max(num_workers, 1), 1024)

    var worker_build = Slab[List[Int]].create(num_workers)
    var worker_probe = Slab[List[Int]].create(num_workers)
    for _ in range(num_workers):
        worker_build.append(List[Int](capacity=est_per_worker))
        worker_probe.append(List[Int](capacity=est_per_worker))

    comptime probe_o = origin_of(probe_keys)
    comptime builder_o = origin_of(builder)
    var state = MultiKeyParallelProbeState[probe_o, builder_o](
        num_morsels,
        morsel_size,
        num_probe_rows,
        n_keys,
        mask,
        est_per_worker,
        mk_probe_batch_width(),
        worker_build^,
        worker_probe^,
        Pointer(to=builder),
        Pointer(to=probe_keys),
    )
    var task = MultiKeyParallelProbeTask[probe_o, builder_o](Int32(0))
    _ = dispatcher.run_with_state[
        MultiKeyParallelProbeState[probe_o, builder_o],
        MultiKeyParallelProbeTask[probe_o, builder_o],
    ](state, task^, num_workers, cancel_token^, site_id=SITE_JOIN_MULTIKEY)

    var base_build = len(build_matches)
    var base_probe = len(probe_matches)
    var dst_off = List[Int](capacity=num_workers + 1)
    var running = 0
    for w in range(num_workers):
        var nb = len(state.worker_build.get_mut_interior(w))
        var np_ = len(state.worker_probe.get_mut_interior(w))
        if nb != np_:
            raise Error(
                "parallel_multi_key_inner_probe_into: worker "
                + String(w)
                + " emitted "
                + String(nb)
                + " build matches but "
                + String(np_)
                + " probe matches (positional pairing broken)"
            )
        dst_off.append(running)
        running += nb
    dst_off.append(running)
    var total_matches = running

    build_matches.reserve(base_build + total_matches)
    probe_matches.reserve(base_probe + total_matches)
    build_matches.resize(unsafe_uninit_length=base_build + total_matches)
    probe_matches.resize(unsafe_uninit_length=base_probe + total_matches)

    var src_build = List[List[Int]](capacity=num_workers)
    var src_probe = List[List[Int]](capacity=num_workers)
    var copied = List[Int](capacity=num_workers)
    for w in range(num_workers):
        src_build.append(state.worker_build.take_slot_unchecked(w))
        src_probe.append(state.worker_probe.take_slot_unchecked(w))
        copied.append(-1)
    state.worker_build.set_len_unchecked(0)
    state.worker_probe.set_len_unchecked(0)

    try:
        var merged = _run_mk_merge_wave(
            build_matches.unsafe_ptr() + base_build,
            probe_matches.unsafe_ptr() + base_probe,
            dst_off,
            _MKMergeSrc(src_build^, src_probe^, copied^),
            num_workers,
            Pointer(to=dispatcher),
        )

        var copied_total = 0
        for w in range(num_workers):
            copied_total += merged.copied[w]
        if copied_total != total_matches:
            raise Error(
                "parallel_multi_key_inner_probe_into: merge wave copied "
                + String(copied_total)
                + " matches but the prefix scan planned "
                + String(total_matches)
            )
        _ = merged^
    except e:
        # The lists were grown over uninitialised slots for the wave to fill;
        # on failure hand them back with only the rows they held on entry.
        build_matches.resize(unsafe_uninit_length=base_build)
        probe_matches.resize(unsafe_uninit_length=base_probe)
        raise e^

    _ = builder
    _ = probe_keys
    _ = state^
