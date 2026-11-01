# =============================================================================
# SlabHashAggSinkStruct -- the MorselSink of the AggregatorWithStruct kernels
# =============================================================================
#
# A partitioned hash aggregation sink whose aggregates keep a per-group state
# struct (`WelfordState`, `LargestKState`, `MedianState`, ...) instead of one
# scalar: each worker probes its rows into 64 per-partition SlabStorages,
# combine merges the workers partition by partition, and finalize emits one
# RecordBatch of the keys and `Agg.finalize` of every group. One or two Int64
# group keys; the aggregates are the variadic pack `Ss`, the input column of
# aggregate `i` is `INPUT_COLS[i]`.
#
# A one-aggregate, one-key sink takes `_consume_fused_1agg_1key`: the rows are
# counting-sorted by partition and each partition is probed and committed in
# one pass, with no per-batch scratch lists. Other shapes probe every row,
# scatter the row indices by partition, and commit each aggregate partition
# by partition.
# =============================================================================

from std.collections import Array
from std.collections.optional import Optional
from std.memory import OwnedPointer, UnsafePointer
from std.sys import size_of

from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.schema import (
    Field,
    RecordBatch,
    RecordBatchBuilder,
    Schema,
    SchemaBuilder,
)
from komira_async.cancellation.token import CancellationToken
from komira_async.ops.waker_sink import NoopSink
from komira_async.runtime.local_dispatcher import LocalDispatcher
from komira_collections.slab import Slab
from komira_op_agg_hash.flat_hash_agg import _fib_hash_1, _fib_hash_2
from komira_op_agg_state.aggregator_with_struct_trait import (
    AggregatorWithStruct,
)
from komira_operator_api.memory_reservation import MemoryReservation
from komira_operator_api.morsel_sink import (
    FinalizeOutput,
    MorselSink,
    NeverMorselSource,
    PARTITIONS_UNREVIEWED,
    SinkCapabilities,
)
from komira_physical_plan.physical_plan import (
    AggSinkData,
    MorselOp,
    ParquetSourceData,
)

from .slab_hash_agg_sink_struct_state import (
    N_PARTITIONS_SHAPE_B,
    SlabHashAggGlobal,
    SlabHashAggLocal,
    _partition_for_shape_b,
)
from .slab_storage import SlabStorage


# =============================================================================
# SlabHashAggSinkStruct -- variadic over AggregatorWithStruct kernels
# =============================================================================


struct SlabHashAggSinkStruct[
    INPUT_COLS: Array[Int, 8] = [-1, -1, -1, -1, -1, -1, -1, -1],
    *Ss: AggregatorWithStruct,
](MorselSink):
    """SlabStorage-backed hash aggregation sink for `AggregatorWithStruct`
    kernels.

    The variadic `*Ss` is the last type parameter; `Ss.__len__()` is the
    aggregate count, and aggregate `i` reads input column `INPUT_COLS[i]`.

    One or two Int64 group keys (the constructor raises on more). The first
    key is batch column `key_col_idx`, the second (if any) the column after
    it: the group-by columns come first in a decoded batch.
    """

    comptime Local = SlabHashAggLocal
    comptime Global = SlabHashAggGlobal
    comptime Output = RecordBatch
    comptime Source = NeverMorselSource

    # --- Immutable sink config -------------------------------------------
    var _agg_data: OwnedPointer[AggSinkData]
    var _pq_data: OwnedPointer[ParquetSourceData]

    var _num_keys: Int
    var _num_aggs: Int
    var _num_workers: Int
    var _initial_capacity: Int
    var _key_col_idx: Int

    # --- Construction -----------------------------------------------------

    @staticmethod
    def _compute_per_worker_capacity(
        estimated_groups: Int, num_workers: Int
    ) -> Int:
        """`max(64, next_pow2(estimated_groups / num_workers * 1.5))`."""
        if num_workers <= 0:
            return 64
        if estimated_groups <= 0:
            return 64
        var raw = estimated_groups * 3 // (num_workers * 2)
        if raw < 64:
            return 64
        var cap = 64
        while cap < raw:
            cap *= 2
        return cap

    def __init__(
        out self,
        var agg_data: AggSinkData,
        var pq_data: ParquetSourceData,
        var operators: Slab[MorselOp],
        num_workers: Int,
        key_col_idx: Int = 0,
    ) raises:
        """Construct from the plan's aggregate and source data. One or two
        group keys; more raise. `key_col_idx` is the batch column of the
        first key; a second key is the next column. `operators` is
        accepted and dropped: this sink runs no per-row operator."""
        var num_keys = len(agg_data.group_by_exprs)
        var num_aggs = len(agg_data.agg_exprs)

        if num_keys != 1 and num_keys != 2:
            raise Error(
                "SlabHashAggSinkStruct: only num_keys in {1, 2} supported;"
                " got num_keys=", num_keys,
            )

        # The plan's aggregate count must equal the pack the caller
        # monomorphized on.
        comptime n_aggs_param = Self.Ss.__len__()
        if num_aggs != n_aggs_param:
            raise Error(
                "SlabHashAggSinkStruct: agg_data.agg_exprs length",
                num_aggs,
                "does not match variadic pack length",
                n_aggs_param,
            )

        self._num_keys = num_keys
        self._num_aggs = num_aggs
        self._num_workers = num_workers
        self._key_col_idx = key_col_idx
        self._initial_capacity = Self._compute_per_worker_capacity(
            agg_data.estimated_groups, num_workers
        )

        self._agg_data = OwnedPointer(agg_data^)
        self._pq_data = OwnedPointer(pq_data^)
        _ = operators^

    @staticmethod
    def new(
        var agg_data: AggSinkData,
        var pq_data: ParquetSourceData,
        var operators: Slab[MorselOp],
        num_workers: Int,
        key_col_idx: Int = 0,
    ) raises -> Self:
        """Factory form of the constructor."""
        return Self(agg_data^, pq_data^, operators^, num_workers, key_col_idx)

    # =========================================================================
    # MorselSink trait surface
    # =========================================================================

    def init_local(self) raises -> Self.Local:
        """A placeholder Local: the per-worker tables live in the Global.
        No memory reservation is taken; these sinks do not spill."""
        var local = Self.Local()
        return local^

    def init_global(self, out sink_global: Self.Global) raises:
        """Build the Global: every per-worker, per-partition storage with
        state strides `[Ss[i].STATE_BYTES, ...]` and `_num_keys` Int64 key
        columns, before any `consume`."""
        var strides = List[Int](capacity=self._num_aggs)
        comptime for i in range(Self.Ss.__len__()):
            strides.append(Self.Ss[i].STATE_BYTES)

        sink_global = Self.Global(
            num_workers=self._num_workers,
            num_keys=self._num_keys,
            num_aggs=self._num_aggs,
            per_worker_capacity=self._initial_capacity,
            agg_state_strides_in=Optional[List[Int]](strides^),
        )

        var total = self._num_workers * N_PARTITIONS_SHAPE_B
        for i in range(total):
            ref stg = sink_global._per_worker_storages[i][]
            var dtypes = List[DType](capacity=self._num_keys)
            for _ in range(self._num_keys):
                dtypes.append(DType.int64)
            stg.init_multi_key_mode(dtypes^)

    def consume[
        o_local: Origin[mut=True], o_global: Origin[mut=True],
    ](
        self,
        worker_id: Int,
        ref [o_local] local: Self.Local,
        ref [o_global] sink_global: Self.Global,
        var batch: RecordBatch,
    ) raises:
        """Fold one batch into worker `worker_id`'s tables.

        One aggregate and one key: `_consume_fused_1agg_1key`. Otherwise:
        (1) read the Int64 key columns in place, (2) probe every row into
        its partition's table, recording its entry id and partition, (3)
        `init_state_with_struct` each new group, (4) scatter the row
        indices by partition, (5) per aggregate and partition, gather the
        inputs and `commit_aggregator_with_struct`. Memory is unbounded:
        these sinks do not spill.
        """
        var _ = local._placeholder  # acknowledge borrow
        var _ = sink_global.claim.load()  # acknowledge borrow

        var num_rows = batch.num_rows()
        if num_rows == 0:
            return

        comptime if Self.Ss.__len__() == 1:
            if self._num_keys == 1:
                self._consume_fused_1agg_1key(
                    worker_id, sink_global, batch^, num_rows,
                )
                return

        # 1) The key column(s), read in place (no copy of the column).
        ref key_col = batch.column_at(self._key_col_idx)
        # SAFETY: `key_col` (and thus `batch`) stays live through the probe
        # loop below. Int64 stride; `_offset` carries any zero-copy slice.
        var key_view0 = key_col._data.view_ro()
        var key_ptr0 = key_view0._unsafe_ptr().bitcast[Scalar[DType.int64]]()
        var key_off0 = key_col._offset

        # 2) Per-row probe into the row's partition. The 1-key / 2-key
        # branch is outside the row loop.
        var entry_ids = List[Int32](capacity=num_rows)
        entry_ids.resize(unsafe_uninit_length=num_rows)
        var partition_ids = List[Int8](capacity=num_rows)
        partition_ids.resize(unsafe_uninit_length=num_rows)

        if self._num_keys == 2:
            # Two keys; `_fib_hash_2` is the hash SlabStorage recomputes
            # for a stored (Int64, Int64) key, so the two must agree.
            ref key1_col = batch.column_at(self._key_col_idx + 1)
            # SAFETY: same liveness contract as `key_col` above.
            var key_view1 = key1_col._data.view_ro()
            var key_ptr1 = key_view1._unsafe_ptr().bitcast[Scalar[DType.int64]]()
            var key_off1 = key1_col._offset
            for r in range(num_rows):
                var k0 = (key_ptr0 + key_off0 + r)[]
                var k1 = (key_ptr1 + key_off1 + r)[]
                var h = _fib_hash_2(k0, k1)
                var p = _partition_for_shape_b(h)
                partition_ids[r] = Int8(p)
                ref part_storage = sink_global.partition_storage_ref(
                    worker_id, p
                )
                # (k0, k1) stay in registers through the compare.
                var pair = part_storage.probe_or_insert_2int64_with_hash(
                    h, k0, k1
                )
                var handle = pair[0]
                var was_new = pair[1]
                entry_ids[r] = Int32(handle._entry_idx)

                # 3) A new group gets `init()` of every aggregate.
                if was_new:
                    comptime for ai in range(Self.Ss.__len__()):
                        part_storage.init_state_with_struct[ai, Self.Ss[ai]](
                            handle
                        )
        else:
            # One key: the probe reads the key as its 8 bytes.
            for r in range(num_rows):
                var key = (key_ptr0 + key_off0 + r)[]
                var h = _fib_hash_1(key)
                var p = _partition_for_shape_b(h)
                partition_ids[r] = Int8(p)
                ref part_storage = sink_global.partition_storage_ref(
                    worker_id, p
                )
                var pair = part_storage.probe_or_insert_multi_key_with_hash(
                    h, _key_bytes(key)
                )
                var handle = pair[0]
                var was_new = pair[1]
                entry_ids[r] = Int32(handle._entry_idx)

                # 3) A new group gets `init()` of every aggregate.
                if was_new:
                    comptime for ai in range(Self.Ss.__len__()):
                        part_storage.init_state_with_struct[ai, Self.Ss[ai]](handle)

        # 4) Scatter the row indices by partition (shared by all
        # aggregates).
        var avg_per_part = max(num_rows // N_PARTITIONS_SHAPE_B + 1, 16)
        var per_part_rows = List[List[Int32]](capacity=N_PARTITIONS_SHAPE_B)
        for _ in range(N_PARTITIONS_SHAPE_B):
            per_part_rows.append(List[Int32](capacity=avg_per_part * 2))
        for r in range(num_rows):
            var p = Int(partition_ids[r])
            per_part_rows[p].append(Int32(r))

        # 5) Commit each aggregate, partition by partition.
        comptime for ai in range(Self.Ss.__len__()):
            comptime COL = Self.INPUT_COLS[ai]
            self._commit_slot_partitioned_with_struct[
                ai, Self.Ss[ai], COL,
            ](
                sink_global, worker_id, batch, entry_ids, per_part_rows,
            )

        # Acknowledge.
        _ = entry_ids^
        _ = partition_ids^
        _ = per_part_rows^
        _ = batch^

    # ------------------------------------------------------------------------
    # _consume_fused_1agg_1key -- one aggregate, one key
    # ------------------------------------------------------------------------

    def _consume_fused_1agg_1key[
        o_global: Origin[mut=True],
    ](
        self,
        worker_id: Int,
        ref [o_global] sink_global: Self.Global,
        var batch: RecordBatch,
        num_rows: Int,
    ) raises:
        """One-key, one-aggregate consume, probing partition by partition.

        Three passes, but each pass is cache-friendly:
          (1) sequential scan: compute `partition = _partition_for_shape_b(
              _fib_hash_1(key))` per row, bump per-partition counts.
          (2) counting-sort the row indices into one `Int32` buffer so a
              partition's rows are contiguous (`sorted[off[p] : off[p+1]]`).
          (3) for each partition p: resolve its table once, then probe,
              init if new, and update in place for each of its rows. The
              partition's table (about 1/64 of the worker's groups) stays
              in L1/L2 for all of them, where probing rows in arrival order
              would jump between 64 tables. The `sorted` and `counts`
              buffers cost 4 bytes a row plus 64 ints.

        Only for `Self.Ss.__len__() == 1`; `consume` also checks
        `_num_keys == 1`.
        """
        comptime A0 = Self.Ss[0]
        comptime COL0 = Self.INPUT_COLS[0]
        comptime if A0.InputDType != DType.float64 and A0.InputDType != DType.int64:
            raise Error(
                "SlabHashAggSinkStruct: fused 1-agg path supports Float64"
                " / Int64 input only; got InputDType=",
                String(A0.InputDType),
            )

        # The key and value columns, read in place.
        ref key_col = batch.column_at(self._key_col_idx)
        # SAFETY: `key_col` (and `batch`) stay live through the loops below.
        var key_view = key_col._data.view_ro()
        var key_ptr = key_view._unsafe_ptr().bitcast[Scalar[DType.int64]]()
        var key_off = key_col._offset
        ref val_col = batch.column_at(COL0)
        # SAFETY: same liveness contract as `key_col`.
        var val_view = val_col._data.view_ro()
        var val_ptr = val_view._unsafe_ptr().bitcast[Scalar[A0.InputDType]]()
        var val_off = val_col._offset

        # --- Pass 1: per-row partition assignment + per-partition counts ---
        var part_ids = List[UInt8](capacity=num_rows)
        part_ids.resize(unsafe_uninit_length=num_rows)
        var counts = Array[Int32, N_PARTITIONS_SHAPE_B](fill=Int32(0))
        for r in range(num_rows):
            var key = (key_ptr + key_off + r)[]
            var p = _partition_for_shape_b(_fib_hash_1(key))
            part_ids[r] = UInt8(p)
            counts[p] += Int32(1)

        # --- Pass 2: counting-sort row indices into one contiguous buffer ---
        # `offs[p]` = start index of partition p's slice in `sorted`;
        # we also keep a moving `cursor[p]` to scatter into.
        var offs = Array[Int32, N_PARTITIONS_SHAPE_B](fill=Int32(0))
        var running = Int32(0)
        for p in range(N_PARTITIONS_SHAPE_B):
            offs[p] = running
            running += counts[p]
        var cursor = Array[Int32, N_PARTITIONS_SHAPE_B](uninitialized=True)
        for p in range(N_PARTITIONS_SHAPE_B):
            cursor[p] = offs[p]
        var sorted_rows = List[Int32](capacity=num_rows)
        sorted_rows.resize(unsafe_uninit_length=num_rows)
        for r in range(num_rows):
            var p = Int(part_ids[r])
            var c = Int(cursor[p])
            sorted_rows[c] = Int32(r)
            cursor[p] = Int32(c + 1)

        # --- Pass 3: per-partition probe + commit (HT stays cache-hot) ---
        for p in range(N_PARTITIONS_SHAPE_B):
            var start = Int(offs[p])
            var end = start + Int(counts[p])
            if start == end:
                continue
            ref part_storage = sink_global.partition_storage_ref(worker_id, p)
            for si in range(start, end):
                var r = Int(sorted_rows[si])
                var key = (key_ptr + key_off + r)[]
                var h = _fib_hash_1(key)
                var pair = part_storage.probe_or_insert_multi_key_with_hash(
                    h, _key_bytes(key)
                )
                var handle = pair[0]
                if pair[1]:
                    part_storage.init_state_with_struct[0, A0](handle)
                # The state slab's base is re-read after the probe: an
                # insert may have grown the table and moved the slab.
                # SAFETY: entry id < num_groups after the probe; slab 0 has
                # stride A0.STATE_BYTES.
                var inner_base = part_storage._agg_slab_byte_base[0]().bitcast[
                    A0.StateStruct
                ]()
                ref s = (inner_base + Int(handle._entry_idx))[]
                A0.update(s, (val_ptr + val_off + r)[])

        _ = part_ids^
        _ = sorted_rows^
        _ = batch^

    # ------------------------------------------------------------------------
    # _commit_slot_partitioned_with_struct -- per-partition gather + commit
    # ------------------------------------------------------------------------

    def _commit_slot_partitioned_with_struct[
        AggIdx: Int, Agg: AggregatorWithStruct, ColIdx: Int,
        o_global: Origin[mut=True],
    ](
        self,
        ref [o_global] sink_global: Self.Global,
        worker_id: Int,
        ref batch: RecordBatch,
        ref entry_ids: List[Int32],
        ref per_part_rows: List[List[Int32]],
    ) raises:
        """Commit aggregate `AggIdx` over every partition: gather the
        partition's entry ids and input values, then
        `commit_aggregator_with_struct[AggIdx, Agg]`. Float64 and Int64
        inputs; any other input type raises.
        """
        comptime if Agg.InputDType == DType.float64:
            # The value column, read in place.
            ref vcol = batch.column_at(ColIdx)
            # SAFETY: `vcol`/`batch` stay live through the gather loop below.
            var vview = vcol._data.view_ro()
            var vptr = vview._unsafe_ptr().bitcast[Scalar[DType.float64]]()
            var voff = vcol._offset
            for p in range(N_PARTITIONS_SHAPE_B):
                ref rows_p = per_part_rows[p]
                var n_p = len(rows_p)
                if n_p == 0:
                    continue
                var part_eids = List[Int32](capacity=n_p)
                part_eids.resize(unsafe_uninit_length=n_p)
                var part_vals = List[Float64](capacity=n_p)
                part_vals.resize(unsafe_uninit_length=n_p)
                for k in range(n_p):
                    var r = Int(rows_p[k])
                    part_eids[k] = entry_ids[r]
                    part_vals[k] = (vptr + voff + r)[]
                var part_eids_span = Span[Int32, origin_of(part_eids)](
                    unsafe_ptr=part_eids.unsafe_ptr(), length=n_p,
                )
                var part_vals_bytes = Span[UInt8, origin_of(part_vals)](
                    unsafe_ptr=part_vals.unsafe_ptr().bitcast[UInt8](),
                    length=n_p * 8,
                )
                ref part_storage = sink_global.partition_storage_ref(
                    worker_id, p
                )
                part_storage.commit_aggregator_with_struct[AggIdx, Agg](
                    part_eids_span, part_vals_bytes, n_p,
                )
                _ = part_eids^
                _ = part_vals^
        elif Agg.InputDType == DType.int64:
            # The value column, read in place.
            ref vcol = batch.column_at(ColIdx)
            # SAFETY: `vcol`/`batch` stay live through the gather loop below.
            var vview = vcol._data.view_ro()
            var vptr = vview._unsafe_ptr().bitcast[Scalar[DType.int64]]()
            var voff = vcol._offset
            for p in range(N_PARTITIONS_SHAPE_B):
                ref rows_p = per_part_rows[p]
                var n_p = len(rows_p)
                if n_p == 0:
                    continue
                var part_eids = List[Int32](capacity=n_p)
                part_eids.resize(unsafe_uninit_length=n_p)
                var part_vals = List[Int64](capacity=n_p)
                part_vals.resize(unsafe_uninit_length=n_p)
                for k in range(n_p):
                    var r = Int(rows_p[k])
                    part_eids[k] = entry_ids[r]
                    part_vals[k] = (vptr + voff + r)[]
                var part_eids_span = Span[Int32, origin_of(part_eids)](
                    unsafe_ptr=part_eids.unsafe_ptr(), length=n_p,
                )
                var part_vals_bytes = Span[UInt8, origin_of(part_vals)](
                    unsafe_ptr=part_vals.unsafe_ptr().bitcast[UInt8](),
                    length=n_p * 8,
                )
                ref part_storage = sink_global.partition_storage_ref(
                    worker_id, p
                )
                part_storage.commit_aggregator_with_struct[AggIdx, Agg](
                    part_eids_span, part_vals_bytes, n_p,
                )
                _ = part_eids^
                _ = part_vals^
        else:
            raise Error(
                "SlabHashAggSinkStruct: supports Float64 / Int64 input"
                " only; got InputDType=",
                String(Agg.InputDType),
            )

    # ------------------------------------------------------------------------
    # combine -- set up the per-partition merge (run by combine_partition)
    # ------------------------------------------------------------------------

    def combine[
        o_global: Origin[mut=True], o_mem: Origin[mut=True],
    ](
        self,
        ref [o_global] sink_global: Self.Global,
        var states: Slab[OwnedPointer[Self.Local]],
        ref [o_mem] reservation: MemoryReservation,
    ) raises:
        """Fill `_merged_storages`: entry `p` is the last worker's
        partition `p`, moved out of `_per_worker_storages` (an empty
        placeholder takes its place). `combine_partition` merges the
        other workers into it.
        """
        var _res = reservation.held_bytes()
        _ = states^

        var total_storage_count = len(sink_global._per_worker_storages)
        if total_storage_count == 0:
            return
        var num_workers = total_storage_count // N_PARTITIONS_SHAPE_B
        if num_workers < 1:
            return

        for p in range(N_PARTITIONS_SHAPE_B):
            var survivor_idx = sink_global.worker_partition_index(
                num_workers - 1, p,
            )
            # The placeholder is never read or written, so its strides do
            # not matter; the survivor keeps its own.
            var fresh_placeholder = SlabStorage(
                num_keys=self._num_keys,
                num_aggs=self._num_aggs,
                initial_capacity=0,
            )
            var fresh_owned_ph = OwnedPointer[SlabStorage](
                fresh_placeholder^
            )
            var survivor_owned = sink_global._per_worker_storages.replace(
                survivor_idx, fresh_owned_ph^,
            )
            sink_global._merged_storages.append(survivor_owned^)

    def num_partitions[o: Origin](
        self, ref [o] sink_global: Self.Global
    ) -> Int:
        """N_PARTITIONS_SHAPE_B once `combine` has filled
        `_merged_storages`, else 1."""
        var _ = sink_global.claim.load()  # acknowledge borrow
        if len(sink_global._merged_storages) == N_PARTITIONS_SHAPE_B:
            return N_PARTITIONS_SHAPE_B
        return PARTITIONS_UNREVIEWED

    def combine_partition[o_global: Origin[mut=True]](
        self,
        ref [o_global] sink_global: Self.Global,
        partition_idx: Int,
    ) raises:
        """Merge every other worker's partition `partition_idx` into its
        survivor with `combine_donor_keys_with_struct[*Ss]` (one probe per
        donor group).

        Partitions merge concurrently and safely: each partition index is
        claimed by one worker, the Global outlives the dispatch, and no
        call grows `_merged_storages` or writes a donor.
        """
        var p = partition_idx
        if p < 0 or p >= N_PARTITIONS_SHAPE_B:
            raise Error(
                "SlabHashAggSinkStruct.combine_partition: invalid"
                " partition_idx=", String(p),
            )

        var total_storage_count = len(sink_global._per_worker_storages)
        if total_storage_count == 0:
            return
        var num_workers = total_storage_count // N_PARTITIONS_SHAPE_B
        if num_workers < 1:
            return

        ref survivor_p = sink_global._merged_storages[p][]

        for w in range(0, num_workers - 1):
            var donor_idx = sink_global.worker_partition_index(w, p)
            ref donor_storage = sink_global._per_worker_storages[donor_idx][]
            survivor_p.combine_donor_keys_with_struct[*Self.Ss](
                donor_storage
            )

    def prepare_finalize[o: Origin[mut=True]](
        self,
        ref [o] sink_global: Self.Global,
    ) raises:
        """Nothing to prepare."""
        var _ = sink_global.claim.load()

    # ------------------------------------------------------------------------
    # finalize -- one RecordBatch from the merged partition survivors
    # ------------------------------------------------------------------------

    def finalize[disp_o: Origin[mut=True]](
        self,
        var sink_global: Self.Global,
        dispatcher_ptr: Pointer[LocalDispatcher[NoopSink], disp_o],
        cancel_token: CancellationToken,
    ) raises -> FinalizeOutput[Self]:
        """Emit the merged groups as one RecordBatch: the Int64 key
        column(s), then one `PrimitiveArray[Ss[ai].OutputDType]` column
        per aggregate, each partition writing its slice in turn.
        """
        var _ = dispatcher_ptr
        var _ = cancel_token

        var num_merged = len(sink_global._merged_storages)

        if num_merged == 0:
            var empty_batch = self._build_empty_output_batch()
            var _claim = sink_global.claim.load()
            var out_slab = Slab[Self.Output].create(1)
            out_slab.append(empty_batch^)
            return FinalizeOutput[Self](
                out_slab^,
            )

        var total_groups = 0
        for p in range(num_merged):
            total_groups += sink_global._merged_storages[p][].num_groups()

        var batch = self._build_output_batch_partitioned(
            sink_global, total_groups,
        )

        var _claim = sink_global.claim.load()

        var out_slab = Slab[Self.Output].create(1)
        out_slab.append(batch^)
        return FinalizeOutput[Self](
            out_slab^,
        )

    def _build_empty_output_batch(self) raises -> RecordBatch:
        """Zero-row RecordBatch matching the output schema shape."""
        var sb = SchemaBuilder()
        var bb = RecordBatchBuilder()

        var fields = List[Field]()
        Self._extract_schema_fields(
            self._agg_data[].output_schema, fields
        )

        # `_num_keys` empty Int64 key columns.
        for ki in range(self._num_keys):
            sb.add_field(fields[ki].copy())
            var k_arr = PrimitiveArray[DType.int64].allocate(0)
            bb.add_column(Column.from_primitive[DType.int64](k_arr^))

        # One empty column per aggregate.
        comptime for ai in range(Self.Ss.__len__()):
            Self._append_empty_agg_column[Self.Ss[ai]](
                sb, bb, fields,
                slot_idx=ai, num_keys=self._num_keys,
            )

        return bb.build(sb.build())

    @staticmethod
    def _extract_schema_fields[
        sch_o: Origin[mut=False]
    ](
        ref [sch_o] schema: Schema,
        mut fields: List[Field],
    ) raises:
        """Copy every Field (with its metadata) out of `schema`, which is
        not copyable, so the output schema carries them."""
        var num_fields = schema.num_columns()
        for i in range(num_fields):
            fields.append(schema.field_at(i))

    @staticmethod
    def _append_empty_agg_column[Agg: AggregatorWithStruct](
        mut sb: SchemaBuilder,
        mut bb: RecordBatchBuilder,
        fields: List[Field],
        slot_idx: Int,
        num_keys: Int,
    ) raises:
        """Append a zero-row `Agg.OutputDType` column for aggregate
        `slot_idx`."""
        var out_idx = num_keys + slot_idx
        sb.add_field(fields[out_idx].copy())
        var arr = PrimitiveArray[Agg.OutputDType].allocate(0)
        bb.add_column(Column.from_primitive[Agg.OutputDType](arr^))

    def _build_output_batch_partitioned[
        o_global: Origin[mut=True]
    ](
        self,
        ref [o_global] sink_global: Self.Global,
        total_groups: Int,
    ) raises -> RecordBatch:
        """Concatenate the partition survivors into one RecordBatch of
        `total_groups` rows: each partition's `finalize_keys_*` and
        `finalize_aggregator_with_struct` write their slice at the
        running group offset."""
        var sb = SchemaBuilder()
        var bb = RecordBatchBuilder()

        var fields = List[Field]()
        Self._extract_schema_fields(
            self._agg_data[].output_schema, fields
        )

        var n_part = len(sink_global._merged_storages)

        # 1) The key column(s): two keys are split out of each group's
        # packed key by `finalize_keys_multi_2col`; one by
        # `finalize_keys_int64`.
        if self._num_keys == 2:
            sb.add_field(fields[0].copy())
            sb.add_field(fields[1].copy())
            var k0_arr = PrimitiveArray[DType.int64].allocate(total_groups)
            var k1_arr = PrimitiveArray[DType.int64].allocate(total_groups)
            var k0_view = k0_arr.view_mut()
            var k1_view = k1_arr.view_mut()
            var k0_ptr = k0_view._unsafe_ptr().bitcast[Scalar[DType.int64]]()
            var k1_ptr = k1_view._unsafe_ptr().bitcast[Scalar[DType.int64]]()
            var k_offset_groups = 0
            for p in range(n_part):
                ref part_storage = sink_global._merged_storages[p][]
                var n_p = part_storage.num_groups()
                if n_p > 0:
                    var part_k0_bytes = Span[UInt8, origin_of(k0_arr)](
                        unsafe_ptr=(k0_ptr + k_offset_groups).bitcast[UInt8](),
                        length=n_p * 8,
                    )
                    var part_k1_bytes = Span[UInt8, origin_of(k1_arr)](
                        unsafe_ptr=(k1_ptr + k_offset_groups).bitcast[UInt8](),
                        length=n_p * 8,
                    )
                    part_storage.finalize_keys_multi_2col(
                        part_k0_bytes, part_k1_bytes
                    )
                    k_offset_groups += n_p
            bb.add_column(Column.from_primitive[DType.int64](k0_arr^))
            bb.add_column(Column.from_primitive[DType.int64](k1_arr^))
        else:
            sb.add_field(fields[0].copy())
            var k_arr = PrimitiveArray[DType.int64].allocate(total_groups)
            var k_view = k_arr.view_mut()
            var k_ptr = k_view._unsafe_ptr().bitcast[Scalar[DType.int64]]()
            var k_offset_groups = 0
            for p in range(n_part):
                ref part_storage = sink_global._merged_storages[p][]
                var n_p = part_storage.num_groups()
                if n_p > 0:
                    var part_k_bytes = Span[UInt8, origin_of(k_arr)](
                        unsafe_ptr=(k_ptr + k_offset_groups).bitcast[UInt8](),
                        length=n_p * 8,
                    )
                    part_storage.finalize_keys_int64(part_k_bytes)
                    k_offset_groups += n_p
            bb.add_column(Column.from_primitive[DType.int64](k_arr^))

        # 2) One column per aggregate.
        comptime for ai in range(Self.Ss.__len__()):
            self._append_agg_column_partitioned_with_struct[
                ai, Self.Ss[ai],
            ](
                sb, bb, fields, sink_global,
                total_groups, num_keys=self._num_keys,
            )

        return bb.build(sb.build())

    def _append_agg_column_partitioned_with_struct[
        AggIdx: Int, Agg: AggregatorWithStruct, o_global: Origin[mut=True],
    ](
        self,
        mut sb: SchemaBuilder,
        mut bb: RecordBatchBuilder,
        fields: List[Field],
        ref [o_global] sink_global: Self.Global,
        total_groups: Int,
        num_keys: Int,
    ) raises:
        """Append aggregate `AggIdx`'s column: each partition's
        `finalize_aggregator_with_struct` writes its groups'
        `Scalar[Agg.OutputDType]` results at the running offset."""
        var out_idx = num_keys + AggIdx
        sb.add_field(fields[out_idx].copy())

        var n_part = len(sink_global._merged_storages)
        var arr = PrimitiveArray[Agg.OutputDType].allocate(total_groups)
        var arr_view = arr.view_mut()
        var arr_ptr = arr_view._unsafe_ptr().bitcast[Scalar[Agg.OutputDType]]()
        var offset = 0
        for p in range(n_part):
            ref part_storage = sink_global._merged_storages[p][]
            var n_p = part_storage.num_groups()
            if n_p == 0:
                continue
            var part_bytes = Span[UInt8, origin_of(arr)](
                unsafe_ptr=(arr_ptr + offset).bitcast[UInt8](),
                length=n_p * size_of[Scalar[Agg.OutputDType]](),
            )
            part_storage.finalize_aggregator_with_struct[AggIdx, Agg](
                part_bytes
            )
            offset += n_p
        bb.add_column(Column.from_primitive[Agg.OutputDType](arr^))

    def capabilities(self) -> SinkCapabilities:
        """`output_is_batch` (finalize emits a RecordBatch); every other
        capability is the default."""
        var caps = SinkCapabilities()
        caps.output_is_batch = True
        return caps


@always_inline
def _key_bytes(ref key: Int64) -> Span[UInt8, origin_of(key)]:
    """The 8 bytes of `key`, as the packed one-Int64 key a SlabStorage
    probe takes."""
    return Span[UInt8, origin_of(key)](
        unsafe_ptr=UnsafePointer(to=key).bitcast[UInt8](), length=8
    )
