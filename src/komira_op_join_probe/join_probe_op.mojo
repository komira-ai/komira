# =============================================================================
# join_probe_op -- the streaming single-INT64-key join probe operator
# (`JoinProbeOp`, a `MorselOperatorImpl`): INNER, LEFT, SEMI, ANTI.
# =============================================================================
#
# One probe morsel at a time against a hash table built beforehand from the
# build side and shared by every worker's operator. The driver picks, once,
# what the operator does with a morsel; the operator does not re-decide:
#
#   * LEFT, SEMI, ANTI: the morsel's whole output in one batch
#     (NEED_MORE_INPUT). With `count_only`, SEMI and ANTI emit only the count
#     of kept rows, as a column-less batch (for a COUNT(*) over the join).
#   * INNER with STRATEGY_PERFECT or STRATEGY_RADIX: the auxiliary table's
#     probe, the whole output in one batch.
#   * INNER with a deferred-output state (`deferred`, and a worker slot): the
#     whole morsel drained into a DEFERRED record in the worker's bucket, or,
#     when the deferral rule declines it, assembled now into a STAGED record
#     (`join_deferred`); the morsel leaves the operator empty either way.
#   * INNER otherwise, with a worker slot: RESUMABLE. The morsel moves into
#     the worker's slot and each call emits at most `PROBE_CHUNK_SIZE` pairs'
#     output, returning HAVE_MORE_OUTPUT until the morsel is drained.
#   * INNER without a worker slot: the whole output in one batch.
#
# Every arm honours a selection mask on the probe morsel: a masked-out probe
# row contributes no pair (and no unmatched LEFT or ANTI row). A NULL probe
# key matches nothing. INNER outputs may take the build key column from the
# probe key column (`SingleKeyCse`). Switches are constructor arguments or
# process flags (`join_probe_levers`, `join_probe_narrow`,
# `komira_join_assembly.join_payload_inline`); nothing reads the environment.
# With `wave_decomp` the INNER chained arms add their sub-phase times to
# `komira_operator_api.wave_decomp`.
# =============================================================================

from std.memory import ArcPointer, OwnedPointer
from std.time import perf_counter_ns
from std.builtin.swap import swap

from komira_arrow.record_batch import RecordBatch
from komira_arrow.schema import Schema

from komira_plan_ir.logical_plan import JOIN_INNER, JOIN_LEFT, JOIN_SEMI, JOIN_ANTI
from komira_exec_types.exec_result import (
    ExecResult,
    NEED_MORE_INPUT,
    HAVE_MORE_OUTPUT,
)
from komira_morsel.morsel import Morsel
from komira_morsel.morsel_operator import MorselOperatorImpl
from komira_metrics.metrics_set import (
    MetricsSet,
    MetricsSnapshot,
    new_owned_metrics_set,
)
from komira_operator_api.wave_decomp import wd_jp, wd_jp_counts, wd_note_deferred
from komira_column_kernels.compiler_helpers import gather_batch
from komira_join_assembly.compiler_join_assembly import assemble_join_result
from komira_join_assembly.join_payload_inline import (
    join_pay_subst_alias,
    join_pay_subst_enabled,
    join_pay_subst_note_elided,
    join_pay_subst_note_kept,
)
from komira_op_join_build.join import (
    HashJoinBuilder,
    PROBE_CHUNK_SIZE,
    ProbeInnerState,
)
from komira_op_join_build.join_perfect_hash import PerfectHashJoin

from .join_defer_verdict import DEFER_ADMIT, DEFER_SHAPE, defer_verdict_note
from .join_defer_verdict import deferral_verdict
from .join_deferred import (
    DeferredJoinChunk,
    JoinDeferredState,
    deferred_probe_retained_bytes,
)
from .join_probe_levers import join_probe_buf_note, join_probe_buf_reuse_enabled
from .join_probe_narrow import (
    deferred_chunk_narrowed,
    join_narrow_marshal_enabled,
    join_narrow_marshal_note,
    join_narrow_marshal_note_widened,
    narrow_marshal_admits,
    widen_narrow_index,
)
from .join_probe_op_deferred import drain_deferred_matches
from .join_probe_op_state import (
    STRATEGY_STANDARD,
    STRATEGY_PERFECT,
    STRATEGY_RADIX,
    ColumnarProbeSharedState,
    SingleKeyCse,
    acquire_probe_key,
    ensure_chunk_scratch,
    sel_keep_pair,
    sel_keep_single,
)
from .radix_join import RadixPartitionedHashJoin


struct JoinProbeOp(MorselOperatorImpl):
    """The streaming single-key join probe; see the module header.

    The table (`_index`), the build side (`_build_batch`), the output schema
    and the auxiliary tables are shared by every worker's operator and only
    read. `_shared` + `_local_id` is this worker's resume slot (none: no
    resumable arm). `_deferred` is the deferred-output state the driver arms
    only for an INNER chained join whose output is all fixed width.
    """

    var _index: ArcPointer[HashJoinBuilder]
    var _build_batch: ArcPointer[RecordBatch]
    var _left_key_name: String
    var _right_key_name: String
    var _output_schema: ArcPointer[Schema]
    var _join_type: UInt8
    var _strategy: UInt8
    var _perfect: Optional[ArcPointer[PerfectHashJoin]]
    var _radix: Optional[ArcPointer[RadixPartitionedHashJoin]]
    var _shared: Optional[ArcPointer[ColumnarProbeSharedState]]
    var _local_id: Int
    var _count_only: Bool
    var _metrics: OwnedPointer[MetricsSet]
    var _cse: SingleKeyCse
    var _deferred: Optional[ArcPointer[JoinDeferredState]]
    # Per-worker record counter: the order tiebreak of two records sharing
    # `(partition_id, origin_hint)` (`DeferredJoinChunk.seq`).
    var _deferred_seq: Int
    var _nt_store: Bool
    var _wave_decomp: Bool

    def __init__(
        out self,
        var index: ArcPointer[HashJoinBuilder],
        var build_batch: ArcPointer[RecordBatch],
        var left_key_name: String,
        var right_key_name: String,
        var output_schema: ArcPointer[Schema],
        join_type: UInt8 = JOIN_INNER,
        var shared: Optional[ArcPointer[ColumnarProbeSharedState]] = None,
        local_id: Int = -1,
        strategy: UInt8 = STRATEGY_STANDARD,
        var perfect: Optional[ArcPointer[PerfectHashJoin]] = None,
        var radix: Optional[ArcPointer[RadixPartitionedHashJoin]] = None,
        count_only: Bool = False,
        var deferred: Optional[ArcPointer[JoinDeferredState]] = None,
        nt_store: Bool = True,
        wave_decomp: Bool = False,
    ) raises:
        """One worker's probe operator.

        Args:
            index: The shared chained table, built on `right_key_name`.
            build_batch: The shared build side.
            left_key_name: The probe key column name.
            right_key_name: The build key column name.
            output_schema: Probe columns then build columns (INNER, LEFT).
            join_type: JOIN_INNER, JOIN_LEFT, JOIN_SEMI or JOIN_ANTI.
            shared: The workers' resume slots; None means no resumable arm.
            local_id: This worker's slot in `shared` (-1: none).
            strategy: The INNER kernel; STRATEGY_PERFECT needs `perfect`,
                STRATEGY_RADIX needs `radix`.
            perfect: The shared perfect-hash table.
            radix: The shared radix-partitioned table.
            count_only: SEMI / ANTI emit only the count of kept rows.
            deferred: The deferred-output state; None keeps INNER undeferred.
            nt_store: Deferred indices are written with non-temporal stores.
            wave_decomp: Record the INNER chained arms' sub-phase times.
        """
        self._index = index^
        self._build_batch = build_batch^
        self._left_key_name = left_key_name^
        self._right_key_name = right_key_name^
        self._output_schema = output_schema^
        self._join_type = join_type
        self._shared = shared^
        self._local_id = local_id
        self._strategy = strategy
        self._perfect = perfect^
        self._radix = radix^
        self._count_only = count_only
        var ms_ptr = new_owned_metrics_set()
        _ = ms_ptr[].register_counter["rows_processed"]()
        _ = ms_ptr[].register_counter["rows_emitted"]()
        _ = ms_ptr[].register_time["elapsed_compute"]()
        self._metrics = ms_ptr^
        self._cse = SingleKeyCse()
        self._deferred = deferred^
        self._deferred_seq = 0
        self._nt_store = nt_store
        self._wave_decomp = wave_decomp

    def metrics_snapshot(self) -> MetricsSnapshot:
        """This operator's metrics, reduced (for EXPLAIN ANALYZE)."""
        return self._metrics[].reduce()

    def execute(mut self, mut morsel: Morsel) raises -> ExecResult:
        """Probe one morsel (or resume one); the arm is the header's."""
        var t0 = perf_counter_ns()
        var rows_in = morsel.batch.num_rows()
        var rc: ExecResult
        if self._join_type != JOIN_INNER:
            rc = self._execute_single_shot(morsel)
        elif self._strategy == STRATEGY_PERFECT and self._perfect:
            rc = self._execute_aux_single(morsel, True)
        elif self._strategy == STRATEGY_RADIX and self._radix:
            rc = self._execute_aux_single(morsel, False)
        elif self._deferred and self._local_id >= 0:
            return self._execute_inner_deferred(morsel, rows_in, t0)
        elif not self._shared or self._local_id < 0:
            rc = self._execute_single_shot(morsel)
        else:
            return self._execute_inner_chunk(morsel, rows_in, t0)
        self._record_metrics(rows_in, morsel.batch.num_rows(), t0)
        return rc

    def _cse_admits(
        mut self, imm probe_batch: RecordBatch, left_key_idx: Int
    ) raises -> Bool:
        return self._cse.admits(
            probe_batch, left_key_idx, self._build_batch[],
            self._left_key_name, self._right_key_name, self._join_type,
        )

    def _assemble_inner(
        mut self,
        imm probe_batch: RecordBatch,
        left_key_idx: Int,
        var probe_list: List[Int],
        var build_list: List[Int],
        cse_ok: Bool,
    ) raises -> RecordBatch:
        """The INNER output at the pairs; the build key shares the probe key
        when `cse_ok`."""
        if cse_ok:
            return assemble_join_result(
                probe_batch,
                self._build_batch[],
                probe_list^,
                build_list^,
                self._output_schema[],
                key_alias_of_right=self._cse.map,
            )
        return assemble_join_result(
            probe_batch,
            self._build_batch[],
            probe_list^,
            build_list^,
            self._output_schema[],
        )

    def _execute_inner_chunk(
        mut self, mut morsel: Morsel, rows_in: Int, t0: Int
    ) raises -> ExecResult:
        """The resumable INNER arm: the next chunk of the morsel in this
        worker's slot (moving a fresh morsel in first)."""
        var wd_on = self._wave_decomp
        var wd_t = t0
        var wd_intake = 0
        var wd_key = 0
        var wd_bufs = 0
        var wd_kernel = 0
        var wd_marshal = 0
        var wd_assemble = 0
        ref shared_ref = self._shared.value()[]
        # SAFETY: `get_mut_interior` hands out this worker's own slot; the
        # driver assigns each worker a distinct `local_id`.
        ref slot = shared_ref.worker_slab.get_mut_interior(self._local_id)

        if not slot.has_pending:
            if morsel.batch.num_rows() == 0:
                return ExecResult(NEED_MORE_INPUT)
            swap(slot.pending, morsel.batch)
            slot.probe_state = ProbeInnerState()
            slot.has_pending = True

        if wd_on:
            var n = perf_counter_ns()
            wd_intake = n - wd_t
            wd_t = n
        var left_key_idx = slot.pending.schema.column_index(self._left_key_name)
        var left_key_arr = acquire_probe_key(slot.pending.column_at(left_key_idx))
        if wd_on:
            var n = perf_counter_ns()
            wd_key = n - wd_t
            wd_t = n

        # Chunk buffers: the slot's own (buffer reuse) or fresh. The slot's
        # are swapped out for the call and back after it.
        var build_buf = List[Int]()
        var probe_buf = List[Int]()
        var reuse = join_probe_buf_reuse_enabled()
        if reuse:
            ensure_chunk_scratch(slot.build_matches)
            ensure_chunk_scratch(slot.probe_matches)
            swap(build_buf, slot.build_matches)
            swap(probe_buf, slot.probe_matches)
            join_probe_buf_note(True)
        else:
            build_buf.resize(unsafe_uninit_length=PROBE_CHUNK_SIZE)
            probe_buf.resize(unsafe_uninit_length=PROBE_CHUNK_SIZE)
        var pay_on = self._index[].pay_inline()
        var pay_buf = List[Int64]()
        if pay_on:
            pay_buf.resize(unsafe_uninit_length=PROBE_CHUNK_SIZE)
        if wd_on:
            var n = perf_counter_ns()
            wd_bufs = n - wd_t
            wd_t = n

        var count = self._index[].probe_inner_chunk(
            left_key_arr,
            slot.probe_state,
            Span(build_buf),
            Span(probe_buf),
            Span(pay_buf),
            PROBE_CHUNK_SIZE,
        )
        _ = left_key_arr
        if wd_on:
            var n = perf_counter_ns()
            wd_kernel = n - wd_t
            wd_t = n
        var done = slot.probe_state.done

        if count == 0:
            if reuse:
                swap(build_buf, slot.build_matches)
                swap(probe_buf, slot.probe_matches)
            slot.clear()
            self._record_metrics(rows_in, 0, t0)
            if wd_on:
                wd_marshal = perf_counter_ns() - wd_t
                wd_jp(
                    perf_counter_ns() - t0, wd_intake, wd_key, wd_bufs,
                    wd_kernel, wd_marshal, 0, 0,
                )
                wd_jp_counts(rows_in, 1, 0, 0, 0, 0)
            return ExecResult(NEED_MORE_INPUT)

        # The kernel's `count` and `done` stay raw so the resume is the same
        # with or without a mask; only the kept pairs are assembled.
        var has_mask = slot.pending.has_selection_mask()
        var build_list = List[Int](capacity=count)
        var probe_list = List[Int](capacity=count)
        for i in range(count):
            var pr = probe_buf[i]
            if not has_mask or slot.pending.selection_mask_get(pr):
                build_list.append(build_buf[i])
                probe_list.append(pr)
        if reuse:
            swap(build_buf, slot.build_matches)
            swap(probe_buf, slot.probe_matches)
        var kept = len(probe_list)
        if wd_on:
            var n = perf_counter_ns()
            wd_marshal = n - wd_t
            wd_t = n
        # An inlined payload's values equal the build column's; this assembly
        # gathers the column.
        var cse_ok = self._cse_admits(slot.pending, left_key_idx)
        var chunk = self._assemble_inner(
            slot.pending, left_key_idx, probe_list^, build_list^, cse_ok
        )
        if wd_on:
            var n = perf_counter_ns()
            wd_assemble = n - wd_t
            wd_t = n
        morsel.replace_batch(chunk^)
        var rows_emitted = morsel.batch.num_rows()
        if done:
            slot.clear()
        self._record_metrics(rows_in, rows_emitted, t0)
        if wd_on:
            var install = perf_counter_ns() - wd_t
            wd_jp(
                perf_counter_ns() - t0, wd_intake, wd_key, wd_bufs, wd_kernel,
                wd_marshal, wd_assemble, install,
            )
            wd_jp_counts(rows_in, 1, count, kept, 1, rows_emitted)
        if done:
            return ExecResult(NEED_MORE_INPUT)
        return ExecResult(HAVE_MORE_OUTPUT)

    def _pay_subst_alias(
        mut self, probe_ncols: Int, mut out_alias: List[Int32]
    ) raises -> Bool:
        """True iff every build output column of this morsel can be served
        without the build match index (`join_pay_subst_alias` decides), with
        the probe-side aliases in `out_alias`."""
        out_alias.clear()
        if not self._index[].pay_inline() or not self._cse.map:
            return False
        return join_pay_subst_alias(
            self._index[].pay_build_col(),
            self._build_batch[].num_columns(),
            probe_ncols,
            self._cse.map.value(),
            out_alias,
        )

    def _execute_inner_deferred(
        mut self, mut morsel: Morsel, rows_in: Int, t0: Int
    ) raises -> ExecResult:
        """The deferred INNER arm: drain the whole morsel, then record it as
        DEFERRED (its probe batch and match indices) or, when the deferral
        rule or the output shape declines, as STAGED (assembled now). The
        morsel leaves empty on every path, so nothing flows downstream from
        this call: the records are assembled once, after every worker is
        done."""
        var wd_on = self._wave_decomp
        if wd_on:
            wd_note_deferred()
        var wd_t = t0
        # The probe batch comes out of the morsel FIRST: left in it, an early
        # return would pass the probe morsel downstream as if it were output.
        var probe_owned = RecordBatch()
        swap(probe_owned, morsel.batch)
        var num_probe_rows = probe_owned.num_rows()
        if num_probe_rows == 0:
            self._record_metrics(rows_in, 0, t0)
            if wd_on:
                var n = perf_counter_ns()
                wd_jp(n - t0, n - t0, 0, 0, 0, 0, 0, 0)
                wd_jp_counts(rows_in, 0, 0, 0, 0, 0)
            return ExecResult(NEED_MORE_INPUT)

        var left_key_idx = probe_owned.schema.column_index(self._left_key_name)
        var pay_on = self._index[].pay_inline()
        # The route is chosen before the drain: it decides where the kernel's
        # pairs are written.
        var fuse = narrow_marshal_admits(
            join_narrow_marshal_enabled(),
            probe_owned.has_selection_mask(),
            pay_on,
            num_probe_rows,
            self._index[].num_build,
        )
        # Payload substitution: with an inlined payload and every other build
        # column aliased to a probe column, the build index is dead and is
        # not collected. -1 = the CSE question was not asked here.
        var pre_cse = -1
        var elide = False
        var elide_alias = List[Int32]()
        if pay_on and join_pay_subst_enabled():
            var ok = self._cse_admits(probe_owned, left_key_idx)
            pre_cse = 1 if ok else 0
            if ok:
                elide = self._pay_subst_alias(
                    probe_owned.num_columns(), elide_alias
                )
            if not elide:
                elide_alias = List[Int32]()
        var wd_intake = 0
        if wd_on:
            var n = perf_counter_ns()
            wd_intake = n - wd_t
            wd_t = n

        # Chunk buffers: the worker slot's (buffer reuse, with a slot) or
        # fresh; the slot's are swapped out for the drain and back after it.
        var build_buf = List[Int]()
        var probe_buf = List[Int]()
        var reuse = join_probe_buf_reuse_enabled() and Bool(
            self._shared
        ) and self._local_id >= 0
        if reuse:
            ref slot = self._shared.value()[].worker_slab.get_mut_interior(
                self._local_id
            )
            ensure_chunk_scratch(slot.build_matches)
            ensure_chunk_scratch(slot.probe_matches)
            swap(build_buf, slot.build_matches)
            swap(probe_buf, slot.probe_matches)
            join_probe_buf_note(True)
        else:
            if join_probe_buf_reuse_enabled():
                # On, but no slot to serve it: counted, so the fresh count
                # does not read as "off".
                join_probe_buf_note(False)
            build_buf.resize(unsafe_uninit_length=PROBE_CHUNK_SIZE)
            probe_buf.resize(unsafe_uninit_length=PROBE_CHUNK_SIZE)
        var wd_bufs = 0
        if wd_on:
            wd_bufs = perf_counter_ns() - wd_t

        var drain = drain_deferred_matches(
            self._index[], probe_owned, left_key_idx, fuse, elide,
            self._nt_store, build_buf, probe_buf, wd_on,
        )
        if reuse:
            ref slot = self._shared.value()[].worker_slab.get_mut_interior(
                self._local_id
            )
            swap(build_buf, slot.build_matches)
            swap(probe_buf, slot.probe_matches)
        if wd_on:
            wd_t = perf_counter_ns()
        var matches = drain.matches
        var probe_list = List[Int]()
        var build_list = List[Int]()
        var pay_list = List[Int64]()
        swap(probe_list, drain.probe_list)
        swap(build_list, drain.build_list)
        swap(pay_list, drain.pay_list)
        if matches == 0:
            self._record_metrics(rows_in, 0, t0)
            if wd_on:
                var install = perf_counter_ns() - wd_t
                wd_jp(
                    perf_counter_ns() - t0, wd_intake, drain.key_ns, wd_bufs,
                    drain.kernel_ns, drain.marshal_ns, 0, install,
                )
                wd_jp_counts(
                    rows_in, drain.kernel_calls, drain.raw_pairs, 0, 0, 0
                )
            return ExecResult(NEED_MORE_INPUT)
        # After the zero-match return: `finish` counts a record, and a drain
        # with no pair makes none.
        if fuse:
            drain.sink.finish()

        var cse_ok: Bool
        if pre_cse >= 0:
            cse_ok = pre_cse == 1
        else:
            cse_ok = self._cse_admits(probe_owned, left_key_idx)
        # The deferred assembly assumes the output is exactly the probe
        # columns then the build columns; a morsel whose shape differs, or
        # whose probe columns have no fixed width to price, is staged.
        var shape_ok = (
            probe_owned.num_columns() + self._build_batch[].num_columns()
            == self._output_schema[].num_columns()
        )
        # Rows times width, not buffer length: a morsel cut from a larger
        # decoded buffer shares it, and retains only its own rows' bytes.
        var probe_bytes = deferred_probe_retained_bytes(probe_owned)
        if probe_bytes < 0:
            shape_ok = False
            probe_bytes = 0

        var seq = self._deferred_seq
        self._deferred_seq += 1
        ref dstate = self._deferred.value()[]
        # SAFETY: the bucket slab is sized to the worker count when the state
        # is built and never grows; each worker writes only its own bucket.
        ref bucket = dstate.buckets.get_mut_interior(self._local_id)
        # Retained bytes per match: probe and build indices; plus the payload
        # value when the table inlines one and the build index is kept.
        var retained_per_match = 16
        if pay_on and not elide:
            retained_per_match = 24
        var verdict = deferral_verdict(
            probe_bytes,
            matches,
            dstate.out_row_width,
            dstate.force_defer,
            dstate.out_num_cols,
            dstate.traffic_rule,
            retained_per_match,
            dstate.idx_bytes_per_col,
        )
        defer_verdict_note(verdict if shape_ok else DEFER_SHAPE)
        if shape_ok and verdict == DEFER_ADMIT:
            if fuse:
                bucket.chunks.append(
                    deferred_chunk_narrowed(
                        probe_owned^,
                        drain.sink.take_probe(),
                        drain.sink.take_build(),
                        morsel.partition_id,
                        morsel.origin_hint,
                        seq,
                        cse_ok,
                    )
                )
                join_narrow_marshal_note(True, matches)
            else:
                if pay_on:
                    if elide:
                        join_pay_subst_note_elided()
                    else:
                        join_pay_subst_note_kept()
                bucket.chunks.append(
                    DeferredJoinChunk.deferred_chunk(
                        probe_owned^,
                        probe_list^,
                        build_list^,
                        morsel.partition_id,
                        morsel.origin_hint,
                        seq,
                        cse_ok,
                        pay_list^,
                        self._index[].pay_build_col() if pay_on else -1,
                        elide_alias^,
                        elide,
                        self._nt_store,
                    )
                )
                join_narrow_marshal_note(False, 0)
            self._record_metrics(rows_in, matches, t0)
            if wd_on:
                var install = perf_counter_ns() - wd_t
                wd_jp(
                    perf_counter_ns() - t0, wd_intake, drain.key_ns, wd_bufs,
                    drain.kernel_ns, drain.marshal_ns, 0, install,
                )
                wd_jp_counts(
                    rows_in, drain.kernel_calls, drain.raw_pairs, matches, 0,
                    matches,
                )
            return ExecResult(NEED_MORE_INPUT)

        # STAGED: assembled now, in the same record list so the final order
        # is one sort. A fused drain's indices are widened back first.
        if fuse:
            probe_list = widen_narrow_index(drain.sink.probe32, matches)
            build_list = widen_narrow_index(drain.sink.build32, matches)
            join_narrow_marshal_note_widened(matches)
        elif elide:
            # The drain did not collect the build index and the staged gather
            # needs it (this assembly takes no inlined payload): probe the
            # morsel again on the two-pass route. Only a payload-substituted
            # morsel the deferral rule declines pays this.
            var again_build = List[Int]()
            var again_probe = List[Int]()
            again_build.resize(unsafe_uninit_length=PROBE_CHUNK_SIZE)
            again_probe.resize(unsafe_uninit_length=PROBE_CHUNK_SIZE)
            var again = drain_deferred_matches(
                self._index[], probe_owned, left_key_idx, False, False,
                self._nt_store, again_build, again_probe, False,
            )
            swap(probe_list, again.probe_list)
            swap(build_list, again.build_list)
        var install = 0
        if wd_on:
            var n = perf_counter_ns()
            install = n - wd_t
            wd_t = n
        var chunk = self._assemble_inner(
            probe_owned, left_key_idx, probe_list^, build_list^, cse_ok
        )
        var chunk_rows = chunk.num_rows()
        var wd_assemble = 0
        if wd_on:
            var n = perf_counter_ns()
            wd_assemble = n - wd_t
            wd_t = n
        bucket.chunks.append(
            DeferredJoinChunk.staged_chunk(
                chunk^, morsel.partition_id, morsel.origin_hint, seq, cse_ok,
            )
        )
        self._record_metrics(rows_in, matches, t0)
        if wd_on:
            install += perf_counter_ns() - wd_t
            wd_jp(
                perf_counter_ns() - t0, wd_intake, drain.key_ns, wd_bufs,
                drain.kernel_ns, drain.marshal_ns, wd_assemble, install,
            )
            wd_jp_counts(
                rows_in, drain.kernel_calls, drain.raw_pairs, matches, 1,
                chunk_rows,
            )
        return ExecResult(NEED_MORE_INPUT)

    def _execute_aux_single(
        mut self, mut morsel: Morsel, perfect: Bool
    ) raises -> ExecResult:
        """INNER through the perfect-hash (`perfect`) or radix-partitioned
        table: the whole morsel's output in one batch."""
        var num_probe_rows = morsel.batch.num_rows()
        if num_probe_rows == 0:
            return ExecResult(NEED_MORE_INPUT)
        var left_key_idx = morsel.batch.schema.column_index(self._left_key_name)
        var left_key_arr = acquire_probe_key(morsel.batch.column_at(left_key_idx))
        var build_matches = List[Int](capacity=num_probe_rows)
        var probe_matches = List[Int](capacity=num_probe_rows)
        if perfect:
            self._perfect.value()[].probe_inner_into(
                left_key_arr, build_matches, probe_matches
            )
        else:
            self._radix.value()[].probe_inner_into(
                left_key_arr, build_matches, probe_matches
            )
        _ = left_key_arr
        sel_keep_pair(build_matches, probe_matches, morsel.batch)
        var cse_ok = self._cse_admits(morsel.batch, left_key_idx)
        var chunk = self._assemble_inner(
            morsel.batch, left_key_idx, probe_matches^, build_matches^, cse_ok
        )
        morsel.replace_batch(chunk^)
        return ExecResult(NEED_MORE_INPUT)

    def _execute_single_shot(mut self, mut morsel: Morsel) raises -> ExecResult:
        """LEFT, SEMI, ANTI, and INNER without a worker slot: the whole
        morsel's output in one batch."""
        var num_probe_rows = morsel.batch.num_rows()
        if num_probe_rows == 0:
            return ExecResult(NEED_MORE_INPUT)
        var left_key_idx = morsel.batch.schema.column_index(self._left_key_name)
        var left_key_arr = acquire_probe_key(morsel.batch.column_at(left_key_idx))
        var is_semi = self._join_type == JOIN_SEMI
        var is_anti = self._join_type == JOIN_ANTI

        if self._count_only and (is_semi or is_anti):
            var c: Int
            if morsel.batch.has_selection_mask():
                var kept = self._index[].probe_semi(
                    left_key_arr
                ) if is_semi else self._index[].probe_anti(left_key_arr)
                sel_keep_single(kept, morsel.batch)
                c = len(kept)
            elif is_semi:
                c = self._index[].probe_semi_count(left_key_arr)
            else:
                c = self._index[].probe_anti_count(left_key_arr)
            _ = left_key_arr
            morsel.replace_batch(RecordBatch.count_only(c))
            return ExecResult(NEED_MORE_INPUT)

        var joined: RecordBatch
        if is_semi or is_anti:
            var probe_indices = self._index[].probe_semi(
                left_key_arr
            ) if is_semi else self._index[].probe_anti(left_key_arr)
            # A masked-out probe row is not a kept row, matched or not.
            sel_keep_single(probe_indices, morsel.batch)
            joined = gather_batch(morsel.batch, probe_indices)
        elif self._join_type == JOIN_LEFT:
            var build_matches = List[Int](capacity=num_probe_rows)
            var probe_matches = List[Int](capacity=num_probe_rows)
            self._index[].probe_left_into(
                left_key_arr, build_matches, probe_matches
            )
            sel_keep_pair(build_matches, probe_matches, morsel.batch)
            # No CSE: the build key is NULL on the rows that make it LEFT.
            joined = assemble_join_result(
                morsel.batch,
                self._build_batch[],
                probe_matches^,
                build_matches^,
                self._output_schema[],
                left_nullable=False,
                right_nullable=True,
            )
        else:
            var est = min(num_probe_rows, self._index[].num_build)
            var build_matches = List[Int](capacity=est)
            var probe_matches = List[Int](capacity=est)
            self._index[].probe_inner_into(
                left_key_arr, build_matches, probe_matches
            )
            sel_keep_pair(build_matches, probe_matches, morsel.batch)
            var cse_ok = self._cse_admits(morsel.batch, left_key_idx)
            joined = self._assemble_inner(
                morsel.batch, left_key_idx, probe_matches^, build_matches^,
                cse_ok,
            )
        _ = left_key_arr
        morsel.replace_batch(joined^)
        return ExecResult(NEED_MORE_INPUT)

    @always_inline
    def _record_metrics(mut self, rows_in: Int, rows_out: Int, t0: Int):
        """Add one call's rows and time to this operator's metrics."""
        self._metrics[].counter["rows_processed"]().inc_in_pipeline(
            Int64(rows_in), worker_id=0
        )
        self._metrics[].counter["rows_emitted"]().inc_in_pipeline(
            Int64(rows_out), worker_id=0
        )
        self._metrics[].time["elapsed_compute"]().record_ns_in_pipeline(
            Int64(perf_counter_ns() - t0), worker_id=0
        )
