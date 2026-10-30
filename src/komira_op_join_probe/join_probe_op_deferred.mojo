# =============================================================================
# join_probe_op_deferred -- the drain loop of the streaming probe's DEFERRED
# INNER arm: one whole probe morsel through the chained table, its match
# pairs collected for a deferred record instead of gathered.
# =============================================================================
#
# The kernel (`HashJoinBuilder.probe_inner_chunk`) fills two scratch buffers a
# chunk at a time; the drain moves each chunk's pairs to where the record will
# keep them, on one of three routes chosen before the loop:
#
#   * FUSED (`join_probe_narrow`): straight to their final 4-byte lists;
#   * ELIDE (payload substitution): the probe index and the inlined payload
#     only, the build index being dead;
#   * the two-pass walk: probe index, build index and (when the table carries
#     one) the inlined payload, as `Int`.
#
# A probe row a selection mask excludes contributes no pair on the walk
# routes; the fused route is never taken with a mask. The payload list is
# appended under the same test, in the same pass, so `pay_list[i]` is always
# the payload of `probe_list[i]`.
# =============================================================================

from std.time import perf_counter_ns

from komira_arrow.record_batch import RecordBatch

from komira_op_join_build.join import (
    HashJoinBuilder,
    PROBE_CHUNK_SIZE,
    ProbeInnerState,
)

from .join_probe_narrow import NarrowMatchSink
from .join_probe_op_state import acquire_probe_key


struct DeferredDrain(Movable):
    """What one drain collected, and what it cost (the wave counters).

    On the fused route the pairs are in `sink` and `build_list` /
    `probe_list` are empty; on the elide route `build_list` is empty.
    `matches` is the pairs kept.
    """

    var sink: NarrowMatchSink
    var build_list: List[Int]
    var probe_list: List[Int]
    var pay_list: List[Int64]
    var matches: Int
    var kernel_calls: Int
    var raw_pairs: Int
    var key_ns: Int
    var kernel_ns: Int
    var marshal_ns: Int

    def __init__(out self, var sink: NarrowMatchSink):
        self.sink = sink^
        self.build_list = List[Int]()
        self.probe_list = List[Int]()
        self.pay_list = List[Int64]()
        self.matches = 0
        self.kernel_calls = 0
        self.raw_pairs = 0
        self.key_ns = 0
        self.kernel_ns = 0
        self.marshal_ns = 0


def drain_deferred_matches(
    imm index: HashJoinBuilder,
    imm probe: RecordBatch,
    left_key_idx: Int,
    fuse: Bool,
    elide: Bool,
    nt_store: Bool,
    mut build_scratch: List[Int],
    mut probe_scratch: List[Int],
    wd_on: Bool,
) raises -> DeferredDrain:
    """Probe all of `probe` (key column `left_key_idx`) against `index` and
    collect its pairs on the route `fuse` / `elide` select (see the header).

    `build_scratch` and `probe_scratch` are the kernel's chunk buffers, at
    least `PROBE_CHUNK_SIZE` long. With `wd_on` the key, kernel and marshal
    time are summed into the result.
    """
    var num_probe_rows = probe.num_rows()
    var has_mask = probe.has_selection_mask()
    var pay_on = index.pay_inline()
    var out = DeferredDrain(
        NarrowMatchSink(num_probe_rows if fuse else -1, nt_store)
    )
    # The wide lists are the record's index on the walk routes, reserved at
    # the probe row count (one-to-one, the shape that defers); the fused
    # route never fills them.
    var wide_cap = 0 if fuse else num_probe_rows
    out.build_list = List[Int](capacity=wide_cap)
    out.probe_list = List[Int](capacity=wide_cap)
    out.pay_list = List[Int64](capacity=num_probe_rows if pay_on else 0)
    # An index without an inlined payload never writes the payload buffer,
    # so it is given an empty one.
    var pay_scratch = List[Int64]()
    if pay_on:
        pay_scratch.resize(unsafe_uninit_length=PROBE_CHUNK_SIZE)

    var pstate = ProbeInnerState()
    var t = 0
    while True:
        if wd_on:
            t = perf_counter_ns()
        # The key is re-acquired per chunk; a share costs a reference count.
        var left_key_arr = acquire_probe_key(probe.column_at(left_key_idx))
        if wd_on:
            var n = perf_counter_ns()
            out.key_ns += n - t
            t = n
        # The fused route offers the sink's room, which is never below the
        # phase-split walk's minimum (see `NARROW_HEADROOM`).
        var chunk_cap = PROBE_CHUNK_SIZE
        if fuse:
            chunk_cap = out.sink.chunk_capacity()
        var count = index.probe_inner_chunk(
            left_key_arr,
            pstate,
            Span(build_scratch),
            Span(probe_scratch),
            Span(pay_scratch),
            chunk_cap,
        )
        _ = left_key_arr
        if wd_on:
            var n = perf_counter_ns()
            out.kernel_ns += n - t
            t = n
            out.kernel_calls += 1
            out.raw_pairs += count
        if fuse:
            out.sink.absorb(Span(probe_scratch), Span(build_scratch), count)
        elif elide:
            for i in range(count):
                var pr = probe_scratch[i]
                if not has_mask or probe.selection_mask_get(pr):
                    out.probe_list.append(pr)
                    out.pay_list.append(pay_scratch[i])
        else:
            for i in range(count):
                var pr = probe_scratch[i]
                if not has_mask or probe.selection_mask_get(pr):
                    out.build_list.append(build_scratch[i])
                    out.probe_list.append(pr)
                    if pay_on:
                        out.pay_list.append(pay_scratch[i])
        if wd_on:
            out.marshal_ns += perf_counter_ns() - t
        if pstate.done or count == 0:
            break
    out.matches = out.sink.n if fuse else len(out.probe_list)
    return out^
