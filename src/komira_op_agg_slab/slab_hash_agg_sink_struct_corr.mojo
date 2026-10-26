# =============================================================================
# slab_hash_agg_sink_struct_corr -- the MorselSink of CORR(x, y)
# =============================================================================
#
# A partitioned hash aggregation sink for one `CorrelationAggregator` over two
# input columns, with one or two Int64 group keys. It is separate from
# `SlabHashAggSinkStruct` because that sink reads one input column per
# aggregate through `Agg.update(state, value)`, and CORR's
# `update_bivariate(state, x, y)` reads two: this sink gathers both and calls
# `SlabStorage.commit_corr_aggregator_with_struct`. Partitioning, combine and
# finalize are those of `SlabHashAggSinkStruct`.
#
# The per-group state is the 48-byte bivariate Welford state; x and y are read
# as Float64 (Int64 inputs are converted).
# =============================================================================

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
from komira_op_agg_state.aggregators_struct_builtin import (
    CorrelationAggregator,
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

from .slab_hash_agg_sink_struct import _key_bytes
from .slab_hash_agg_sink_struct_state import (
    N_PARTITIONS_SHAPE_B,
    SlabHashAggGlobal,
    SlabHashAggLocal,
    _partition_for_shape_b,
)
from .slab_storage import SlabStorage


# =============================================================================
# SlabHashAggSinkStructCorr — single-CORR-kernel sink (1 or 2 keys)
# =============================================================================


struct SlabHashAggSinkStructCorr[
    KEY_COL_IDX: Int = 0,
    COL_X: Int = 1,
    COL_Y: Int = 2,
    INPUT_DTYPE: DType = DType.float64,
](MorselSink):
    """SlabStorage-backed CORR(x, y) aggregation sink.

    Comptime parameters (all column indices):
      * KEY_COL_IDX: index of the FIRST group-by key column. The second
        key (if 2-key mode) is at KEY_COL_IDX + 1.
      * COL_X: index of the x column.
      * COL_Y: index of the y column.
    INPUT_DTYPE is the type of both input columns (Float64 or Int64).

    Shape supported: one or two Int64 group keys, one aggregate
    (`CorrelationAggregator`).
    """

    comptime Local = SlabHashAggLocal
    comptime Global = SlabHashAggGlobal
    comptime Output = RecordBatch
    comptime Source = NeverMorselSource

    # --- Immutable sink config -------------------------------------------
    var _agg_data: OwnedPointer[AggSinkData]
    var _pq_data: OwnedPointer[ParquetSourceData]

    var _num_keys: Int
    var _num_workers: Int
    var _initial_capacity: Int

    # --- Construction -----------------------------------------------------

    @staticmethod
    def _compute_per_worker_capacity(
        estimated_groups: Int, num_workers: Int
    ) -> Int:
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
    ) raises:
        """Construct from the plan's aggregate and source data: one or two
        group keys and exactly one aggregate, or raise. `operators` is
        accepted and dropped: this sink runs no per-row operator."""
        var num_keys = len(agg_data.group_by_exprs)
        var num_aggs = len(agg_data.agg_exprs)

        if num_keys != 1 and num_keys != 2:
            raise Error(
                "SlabHashAggSinkStructCorr: only num_keys in {1, 2}"
                " supported; got num_keys=", num_keys,
            )
        if num_aggs != 1:
            raise Error(
                "SlabHashAggSinkStructCorr: exactly 1 CORR agg supported;"
                " got num_aggs=", num_aggs,
            )

        self._num_keys = num_keys
        self._num_workers = num_workers
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
    ) raises -> Self:
        return Self(agg_data^, pq_data^, operators^, num_workers)

    # =========================================================================
    # MorselSink trait surface
    # =========================================================================

    def init_local(self) raises -> Self.Local:
        var local = Self.Local()
        return local^

    def init_global(self, out sink_global: Self.Global) raises:
        """Build the Global: every per-worker, per-partition storage with
        one 48-byte CorrelationState per group and `_num_keys` Int64 key
        columns, before any `consume`."""
        var strides = List[Int](capacity=1)
        strides.append(CorrelationAggregator.STATE_BYTES)

        sink_global = Self.Global(
            num_workers=self._num_workers,
            num_keys=self._num_keys,
            num_aggs=1,
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
        """Fold one batch into worker `worker_id`'s tables:

          1. Probe every row into its partition's table (one or two Int64
             keys), recording its entry id and partition; a new group gets
             `CorrelationAggregator.init()`.
          2. Scatter the row indices by partition.
          3. Per partition, gather (x, y) as Float64 and
             `commit_corr_aggregator_with_struct`.
        """
        var _ = local._placeholder
        var _ = sink_global.claim.load()

        var num_rows = batch.num_rows()
        if num_rows == 0:
            return

        # 1) Key column(s) extraction.
        var key_arr = batch.column_as_primitive_int64(Self.KEY_COL_IDX)

        # 2) Per-row probe with per-partition routing.
        var entry_ids = List[Int32](capacity=num_rows)
        entry_ids.resize(unsafe_uninit_length=num_rows)
        var partition_ids = List[Int8](capacity=num_rows)
        partition_ids.resize(unsafe_uninit_length=num_rows)

        if self._num_keys == 2:
            var key1_arr = batch.column_as_primitive_int64(Self.KEY_COL_IDX + 1)
            for r in range(num_rows):
                var k0 = key_arr.get_typed[Int64](r)
                var k1 = key1_arr.get_typed[Int64](r)
                var h = _fib_hash_2(k0, k1)
                var p = _partition_for_shape_b(h)
                partition_ids[r] = Int8(p)
                ref part_storage = sink_global.partition_storage_ref(
                    worker_id, p
                )
                var pair = part_storage.probe_or_insert_2int64_with_hash(
                    h, k0, k1
                )
                var handle = pair[0]
                var was_new = pair[1]
                entry_ids[r] = Int32(handle._entry_idx)
                if was_new:
                    part_storage.init_state_with_struct[
                        0, CorrelationAggregator
                    ](handle)
        else:
            for r in range(num_rows):
                var key = key_arr.get_typed[Int64](r)
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
                if was_new:
                    part_storage.init_state_with_struct[
                        0, CorrelationAggregator
                    ](handle)

        # 3) Bucket-scatter rows into per-partition lists.
        var avg_per_part = max(num_rows // N_PARTITIONS_SHAPE_B + 1, 16)
        var per_part_rows = List[List[Int32]](capacity=N_PARTITIONS_SHAPE_B)
        for _ in range(N_PARTITIONS_SHAPE_B):
            per_part_rows.append(List[Int32](capacity=avg_per_part * 2))
        for r in range(num_rows):
            var p = Int(partition_ids[r])
            per_part_rows[p].append(Int32(r))

        # 4) Per partition, gather (x, y) as Float64 and commit. An Int64
        # input is converted to Float64; the type branch is comptime.
        comptime if Self.INPUT_DTYPE == DType.float64:
            var x_arr_f64 = batch.column_as_primitive_float64(Self.COL_X)
            var y_arr_f64 = batch.column_as_primitive_float64(Self.COL_Y)
            for p in range(N_PARTITIONS_SHAPE_B):
                ref rows_p = per_part_rows[p]
                var n_p = len(rows_p)
                if n_p == 0:
                    continue
                var part_eids = List[Int32](capacity=n_p)
                part_eids.resize(unsafe_uninit_length=n_p)
                var part_x = List[Float64](capacity=n_p)
                part_x.resize(unsafe_uninit_length=n_p)
                var part_y = List[Float64](capacity=n_p)
                part_y.resize(unsafe_uninit_length=n_p)
                for k in range(n_p):
                    var r = Int(rows_p[k])
                    part_eids[k] = entry_ids[r]
                    part_x[k] = x_arr_f64.get_typed[Float64](r)
                    part_y[k] = y_arr_f64.get_typed[Float64](r)
                var part_eids_span = Span[Int32, origin_of(part_eids)](
                    unsafe_ptr=part_eids.unsafe_ptr(), length=n_p,
                )
                var part_x_bytes = Span[UInt8, origin_of(part_x)](
                    unsafe_ptr=part_x.unsafe_ptr().bitcast[UInt8](),
                    length=n_p * 8,
                )
                var part_y_bytes = Span[UInt8, origin_of(part_y)](
                    unsafe_ptr=part_y.unsafe_ptr().bitcast[UInt8](),
                    length=n_p * 8,
                )
                ref part_storage = sink_global.partition_storage_ref(
                    worker_id, p
                )
                part_storage.commit_corr_aggregator_with_struct[0](
                    part_eids_span, part_x_bytes, part_y_bytes, n_p,
                )
                _ = part_eids^
                _ = part_x^
                _ = part_y^
        elif Self.INPUT_DTYPE == DType.int64:
            var x_arr_i64 = batch.column_as_primitive_int64(Self.COL_X)
            var y_arr_i64 = batch.column_as_primitive_int64(Self.COL_Y)
            for p in range(N_PARTITIONS_SHAPE_B):
                ref rows_p = per_part_rows[p]
                var n_p = len(rows_p)
                if n_p == 0:
                    continue
                var part_eids = List[Int32](capacity=n_p)
                part_eids.resize(unsafe_uninit_length=n_p)
                var part_x = List[Float64](capacity=n_p)
                part_x.resize(unsafe_uninit_length=n_p)
                var part_y = List[Float64](capacity=n_p)
                part_y.resize(unsafe_uninit_length=n_p)
                for k in range(n_p):
                    var r = Int(rows_p[k])
                    part_eids[k] = entry_ids[r]
                    part_x[k] = Float64(x_arr_i64.get_typed[Int64](r))
                    part_y[k] = Float64(y_arr_i64.get_typed[Int64](r))
                var part_eids_span = Span[Int32, origin_of(part_eids)](
                    unsafe_ptr=part_eids.unsafe_ptr(), length=n_p,
                )
                var part_x_bytes = Span[UInt8, origin_of(part_x)](
                    unsafe_ptr=part_x.unsafe_ptr().bitcast[UInt8](),
                    length=n_p * 8,
                )
                var part_y_bytes = Span[UInt8, origin_of(part_y)](
                    unsafe_ptr=part_y.unsafe_ptr().bitcast[UInt8](),
                    length=n_p * 8,
                )
                ref part_storage = sink_global.partition_storage_ref(
                    worker_id, p
                )
                part_storage.commit_corr_aggregator_with_struct[0](
                    part_eids_span, part_x_bytes, part_y_bytes, n_p,
                )
                _ = part_eids^
                _ = part_x^
                _ = part_y^
        else:
            raise Error(
                "SlabHashAggSinkStructCorr: INPUT_DTYPE must be Int64 or"
                " Float64; got ",
                String(Self.INPUT_DTYPE),
            )

        _ = entry_ids^
        _ = partition_ids^
        _ = per_part_rows^
        _ = batch^

    # ------------------------------------------------------------------------
    # combine -- set up the per-partition merge (as SlabHashAggSinkStruct)
    # ------------------------------------------------------------------------

    def combine[
        o_global: Origin[mut=True], o_mem: Origin[mut=True],
    ](
        self,
        ref [o_global] sink_global: Self.Global,
        var states: Slab[OwnedPointer[Self.Local]],
        ref [o_mem] reservation: MemoryReservation,
    ) raises:
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
            var fresh_placeholder = SlabStorage(
                num_keys=self._num_keys,
                num_aggs=1,
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
        var _ = sink_global.claim.load()
        if len(sink_global._merged_storages) == N_PARTITIONS_SHAPE_B:
            return N_PARTITIONS_SHAPE_B
        return PARTITIONS_UNREVIEWED

    def combine_partition[o_global: Origin[mut=True]](
        self,
        ref [o_global] sink_global: Self.Global,
        partition_idx: Int,
    ) raises:
        """Merge every other worker's partition `partition_idx` into its
        survivor with `combine_donor_keys_with_struct`: one probe per donor
        group, `CorrelationAggregator.combine` exactly once per shared
        group (combining a state with a copy of itself doubles n and the
        co-moments, which changes r once a third worker merges in)."""
        var p = partition_idx
        if p < 0 or p >= N_PARTITIONS_SHAPE_B:
            raise Error(
                "SlabHashAggSinkStructCorr.combine_partition: invalid"
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
            survivor_p.combine_donor_keys_with_struct[CorrelationAggregator](
                donor_storage
            )

    def prepare_finalize[o: Origin[mut=True]](
        self,
        ref [o] sink_global: Self.Global,
    ) raises:
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
        var sb = SchemaBuilder()
        var bb = RecordBatchBuilder()

        var fields = List[Field]()
        Self._extract_schema_fields(
            self._agg_data[].output_schema, fields
        )

        for ki in range(self._num_keys):
            sb.add_field(fields[ki].copy())
            var k_arr = PrimitiveArray[DType.int64].allocate(0)
            bb.add_column(Column.from_primitive[DType.int64](k_arr^))

        var out_idx = self._num_keys  # single agg slot
        sb.add_field(fields[out_idx].copy())
        var arr = PrimitiveArray[DType.float64].allocate(0)
        bb.add_column(Column.from_primitive[DType.float64](arr^))

        return bb.build(sb.build())

    @staticmethod
    def _extract_schema_fields[
        sch_o: Origin[mut=False]
    ](
        ref [sch_o] schema: Schema,
        mut fields: List[Field],
    ) raises:
        # Copy every Field (with its metadata) out of the non-copyable
        # schema.
        var num_fields = schema.num_columns()
        for i in range(num_fields):
            fields.append(schema.field_at(i))

    def _build_output_batch_partitioned[
        o_global: Origin[mut=True]
    ](
        self,
        ref [o_global] sink_global: Self.Global,
        total_groups: Int,
    ) raises -> RecordBatch:
        var sb = SchemaBuilder()
        var bb = RecordBatchBuilder()

        var fields = List[Field]()
        Self._extract_schema_fields(
            self._agg_data[].output_schema, fields
        )

        var n_part = len(sink_global._merged_storages)

        # 1) Key column(s).
        if self._num_keys == 2:
            sb.add_field(fields[0].copy())
            sb.add_field(fields[1].copy())
            var k0_arr = PrimitiveArray[DType.int64].allocate(total_groups)
            var k1_arr = PrimitiveArray[DType.int64].allocate(total_groups)
            var k0_ptr = k0_arr._typed_ptr_mut()
            var k1_ptr = k1_arr._typed_ptr_mut()
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
            var k_ptr = k_arr._typed_ptr_mut()
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

        # 2) The single CORR output column (Float64).
        var out_idx = self._num_keys
        sb.add_field(fields[out_idx].copy())
        var arr = PrimitiveArray[DType.float64].allocate(total_groups)
        var arr_ptr = arr._typed_ptr_mut()
        var offset = 0
        for p in range(n_part):
            ref part_storage = sink_global._merged_storages[p][]
            var n_p = part_storage.num_groups()
            if n_p == 0:
                continue
            var part_bytes = Span[UInt8, origin_of(arr)](
                unsafe_ptr=(arr_ptr + offset).bitcast[UInt8](),
                length=n_p * size_of[Scalar[DType.float64]](),
            )
            part_storage.finalize_aggregator_with_struct[
                0, CorrelationAggregator
            ](part_bytes)
            offset += n_p
        bb.add_column(Column.from_primitive[DType.float64](arr^))

        return bb.build(sb.build())

    def capabilities(self) -> SinkCapabilities:
        var caps = SinkCapabilities()
        caps.output_is_batch = True
        return caps
