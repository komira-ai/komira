# =============================================================================
# SlabStorage -- the group table of the struct-state hash aggregation sinks
# =============================================================================
#
# Layout:
#   - `_ht_entries: Slab[UInt8]`      capacity * 8 bytes; stores entry_id + 1
#                                     (0 is the empty slot)
#   - `_fingerprints: Slab[UInt8]`    capacity * 1 byte; `(h >> 56) | 0x80`
#                                     (0 is the empty slot)
#   - `_key_bytes: Slab[UInt8]`       num_groups * key stride; the packed
#                                     composite key of each group, in
#                                     insertion order
#   - `_agg_slab_<0..7>: Slab[UInt8]` one columnar state slab per aggregate,
#                                     `stride[i]` bytes per group
#
# The probe is a SwissTable/F14 group walk: sixteen 1-byte fingerprints are
# compared in one SIMD-16 vector compare against the target and against the
# empty byte. The per-aggregate commits, finalizes and combines are
# monomorphized on a comptime `[AggIdx, Agg: AggregatorWithStruct]` and read
# each state slab as `Agg.StateStruct` (24 bytes for a Welford state, 48 for
# a bivariate one, 520 for a median buffer).
#
# The eight aggregate slabs are eight named fields, not a slab of slabs: a
# `Slab` stores its elements as bytes and does not run their destructors, so
# a heap-owning element type would leak. Slots `[num_aggs, MAX_AGGS)` stay
# empty and their drops are no-ops.
#
# Pointers: every pointer below is derived from a field of `self` (or of a
# donor) with that borrow's origin, lives for one method body, and is
# re-derived after anything that can grow the slab it points into. No public
# method takes or returns one: keys and outputs cross the API as spans.
# =============================================================================

from std.collections import Array
from std.collections.optional import Optional
from std.memory import UnsafePointer

from komira_collections.slab import Slab
from komira_counters.keyeq_census import (
    keyeq_record,
    KEYEQ_SLAB_STRIDE8,
    KEYEQ_SLAB_STRIDE16,
)
from komira_op_agg_hash.flat_hash_agg import EntryHandle
from komira_op_agg_state.aggregator_with_struct_trait import (
    AggregatorWithStruct,
)
from komira_op_agg_state.aggregators_struct_builtin import (
    CorrelationAggregator,
)

from .slab_storage_ck_helpers import (
    _ck_dtype_byte_width,
    _ck_hash_key_bytes,
    _ck_memcmp_keys,
)


# -----------------------------------------------------------------------------
# Tunables
# -----------------------------------------------------------------------------

# Hash-table capacity of a storage built in deferred-allocation mode
# (`initial_capacity <= 0`) on its first insert; growth doubles from here.
comptime _SLAB_DEFAULT_INITIAL_CAPACITY: Int = 64

# Grow at a 7/10 load factor, as FlatHashAggregator does.
comptime _SLAB_LOAD_FACTOR_NUM: Int = 7
comptime _SLAB_LOAD_FACTOR_DEN: Int = 10

# `_ht_entries` sentinel: 0 is an empty slot; a full slot holds entry_id + 1.
comptime _HT_ENTRY_EMPTY: UInt64 = 0

# Slots per SIMD-16 fingerprint compare. A probe aligns its start slot down
# to a 16-slot boundary (`slot & ~15`) and walks whole groups, so the
# capacity is always a power of two and at least 16.
comptime _SIMD_GROUP: Int = 16
"""SwissTable group size (slots per SIMD-16 vector compare)."""

comptime _FP_NONZERO_MASK: UInt8 = 0x80
"""High bit forced on in every stored fingerprint, so a 0 byte is EMPTY."""

comptime _FP_EMPTY: UInt8 = 0
"""Empty-slot fingerprint."""

# One named state slab per aggregate; a storage holds at most eight.
comptime MAX_AGGS: Int = 8


struct SlabStorage(Movable, Deinitable):
    """Hash table of groups with columnar per-aggregate struct state.

    A group is a packed composite key (one to eight fixed-width columns,
    Int64 by default) plus one `Agg.StateStruct` per aggregate. Groups are
    numbered in insertion order (the entry id); every per-group array is
    indexed by it.

    `agg_state_strides_in` gives each aggregate's state size in bytes
    (`Agg.STATE_BYTES`; 8 when omitted). A state slab is zero-filled as it
    grows; `init_state_with_struct` writes `Agg.init()` into a new group's
    slot.
    """

    var _ht_entries: Slab[UInt8]
    var _fingerprints: Slab[UInt8]

    var _agg_slab_0: Slab[UInt8]
    var _agg_slab_1: Slab[UInt8]
    var _agg_slab_2: Slab[UInt8]
    var _agg_slab_3: Slab[UInt8]
    var _agg_slab_4: Slab[UInt8]
    var _agg_slab_5: Slab[UInt8]
    var _agg_slab_6: Slab[UInt8]
    var _agg_slab_7: Slab[UInt8]

    # The composite key: `_num_key_cols` columns packed at
    # `_key_col_offsets[i]`, `_key_col_widths[i]` bytes each, as
    # `_key_dtypes[i]`; `_key_stride_bytes` bytes per group.
    var _key_bytes: Slab[UInt8]
    var _key_stride_bytes: Int
    var _num_key_cols: Int
    var _key_col_offsets: Array[Int, 8]
    var _key_col_widths: Array[Int, 8]
    var _key_dtypes: Array[DType, 8]

    var _capacity: Int
    """Hash table slot count (a power of two, at least 16; 0 before the
    first insert in deferred-allocation mode)."""

    var _num_groups: Int
    """Number of distinct groups inserted so far."""

    var _resize_threshold: Int
    """Grow when `_num_groups + 1` exceeds this: `_capacity * 7 / 10`."""

    var _agg_state_strides: List[Int]
    """Per-aggregate state size in bytes, indexed by AggIdx."""

    var _pre_reserved_capacity: Int
    """Number of groups each active `_agg_slab_<i>` is allocated and
    zero-filled for. Grown by doubling in `_ensure_pre_reserved_capacity`;
    0 in deferred-allocation mode."""

    # -------------------------------------------------------------------
    # Construction
    # -------------------------------------------------------------------

    def __init__(
        out self,
        num_keys: Int,
        num_aggs: Int,
        initial_capacity: Int,
        var agg_state_strides_in: Optional[List[Int]] = None,
    ):
        """Construct an empty SlabStorage keyed by `num_keys` Int64 columns.

        Args:
            num_keys: Group-by key column count (Int64 each; call
                `init_multi_key_mode` before the first insert for other
                key types).
            num_aggs: Aggregate count, at most `MAX_AGGS`.
            initial_capacity: Hash-table capacity hint, rounded up to a
                power of two of at least 16. `0` defers every allocation
                to the first insert.
            agg_state_strides_in: Per-aggregate state size in bytes, one
                positive entry per aggregate, equal to that aggregate's
                `STATE_BYTES`. A mismatch reads and writes state at the
                wrong size. `None` gives 8 bytes per aggregate.
        """
        self._num_groups = 0

        if initial_capacity <= 0:
            self._capacity = 0
            self._resize_threshold = 0
            self._ht_entries = Slab[UInt8]()
            self._fingerprints = Slab[UInt8]()
        else:
            var cap = _SIMD_GROUP
            while cap < initial_capacity:
                cap *= 2
            self._capacity = cap
            self._resize_threshold = (
                cap * _SLAB_LOAD_FACTOR_NUM // _SLAB_LOAD_FACTOR_DEN
            )
            self._ht_entries = Slab[UInt8].create_prefilled(cap * 8)
            self._fingerprints = Slab[UInt8].create_prefilled(cap * 1)

        debug_assert(
            num_aggs <= MAX_AGGS,
            "SlabStorage: num_aggs > MAX_AGGS (8)",
        )
        self._agg_state_strides = List[Int](capacity=num_aggs)
        if agg_state_strides_in:
            var supplied = agg_state_strides_in.unsafe_take()
            debug_assert(
                len(supplied) == num_aggs,
                "SlabStorage: agg_state_strides_in length must equal"
                " num_aggs",
            )
            for i in range(num_aggs):
                var stride_i = supplied[i]
                debug_assert(
                    stride_i > 0,
                    "SlabStorage: agg_state_strides_in entries must be"
                    " positive",
                )
                self._agg_state_strides.append(stride_i)
        else:
            for _ in range(num_aggs):
                self._agg_state_strides.append(8)

        if initial_capacity <= 0:
            self._pre_reserved_capacity = 0
            self._agg_slab_0 = Slab[UInt8]()
            self._agg_slab_1 = Slab[UInt8]()
            self._agg_slab_2 = Slab[UInt8]()
            self._agg_slab_3 = Slab[UInt8]()
            self._agg_slab_4 = Slab[UInt8]()
            self._agg_slab_5 = Slab[UInt8]()
            self._agg_slab_6 = Slab[UInt8]()
            self._agg_slab_7 = Slab[UInt8]()
        else:
            # One zero-filled allocation per active slab, sized for
            # `_capacity` groups; inactive slots stay unallocated.
            self._pre_reserved_capacity = self._capacity
            self._agg_slab_0 = _prefilled_agg_slab(
                self._capacity, self._agg_state_strides, 0
            )
            self._agg_slab_1 = _prefilled_agg_slab(
                self._capacity, self._agg_state_strides, 1
            )
            self._agg_slab_2 = _prefilled_agg_slab(
                self._capacity, self._agg_state_strides, 2
            )
            self._agg_slab_3 = _prefilled_agg_slab(
                self._capacity, self._agg_state_strides, 3
            )
            self._agg_slab_4 = _prefilled_agg_slab(
                self._capacity, self._agg_state_strides, 4
            )
            self._agg_slab_5 = _prefilled_agg_slab(
                self._capacity, self._agg_state_strides, 5
            )
            self._agg_slab_6 = _prefilled_agg_slab(
                self._capacity, self._agg_state_strides, 6
            )
            self._agg_slab_7 = _prefilled_agg_slab(
                self._capacity, self._agg_state_strides, 7
            )

        # Default key shape: `num_keys` Int64 columns, packed.
        self._key_bytes = Slab[UInt8]()
        self._key_stride_bytes = num_keys * 8
        self._num_key_cols = num_keys
        self._key_col_offsets = Array[Int, 8](fill=0)
        self._key_col_widths = Array[Int, 8](fill=0)
        self._key_dtypes = Array[DType, 8](fill=DType.int8)
        for i in range(num_keys):
            self._key_dtypes[i] = DType.int64
            self._key_col_offsets[i] = i * 8
            self._key_col_widths[i] = 8
        var key_bytes_total = self._capacity * self._key_stride_bytes
        if key_bytes_total > 0:
            self._key_bytes = Slab[UInt8].create_prefilled(key_bytes_total)

    # -------------------------------------------------------------------
    # Per-aggregate slab access
    # -------------------------------------------------------------------

    @always_inline
    def _agg_slab_byte_base[
        mut: Bool, o: Origin[mut=mut], //, AggIdx: Int
    ](ref [o] self) -> UnsafePointer[UInt8, o]:
        """Base byte pointer of `_agg_slab_<AggIdx>`, with the origin of the
        borrow of `self`. The caller bitcasts it to `Agg.StateStruct` and
        indexes it by entry id.

        SAFETY: the caller must not dereference past the slab's length
        (`_pre_reserved_capacity * stride`), and must re-derive the pointer
        after any insert, which may grow the slab.
        """
        comptime assert AggIdx >= 0 and AggIdx < MAX_AGGS, (
            "SlabStorage._agg_slab_byte_base: AggIdx out of [0, MAX_AGGS)"
        )
        comptime if AggIdx == 0:
            return self._agg_slab_0._unsafe_ptr().unsafe_origin_cast[o]()
        elif AggIdx == 1:
            return self._agg_slab_1._unsafe_ptr().unsafe_origin_cast[o]()
        elif AggIdx == 2:
            return self._agg_slab_2._unsafe_ptr().unsafe_origin_cast[o]()
        elif AggIdx == 3:
            return self._agg_slab_3._unsafe_ptr().unsafe_origin_cast[o]()
        elif AggIdx == 4:
            return self._agg_slab_4._unsafe_ptr().unsafe_origin_cast[o]()
        elif AggIdx == 5:
            return self._agg_slab_5._unsafe_ptr().unsafe_origin_cast[o]()
        elif AggIdx == 6:
            return self._agg_slab_6._unsafe_ptr().unsafe_origin_cast[o]()
        else:
            return self._agg_slab_7._unsafe_ptr().unsafe_origin_cast[o]()

    def _ensure_pre_reserved_capacity(mut self, min_capacity: Int):
        """Grow each active `_agg_slab_<i>` to hold at least `min_capacity`
        groups, doubling `_pre_reserved_capacity`, and zero-fill the new
        tail. A no-op when the slabs are already large enough. Cold: runs
        once per hash-table growth."""
        if min_capacity <= self._pre_reserved_capacity:
            return

        var new_cap = self._pre_reserved_capacity
        if new_cap == 0:
            new_cap = _SLAB_DEFAULT_INITIAL_CAPACITY
        while new_cap < min_capacity:
            new_cap = new_cap * 2

        var num_aggs = len(self._agg_state_strides)
        comptime for AggIdx in range(MAX_AGGS):
            if AggIdx < num_aggs:
                var stride = self._agg_state_strides[AggIdx]
                self._grow_agg_slab_zero_filled[AggIdx](
                    self._pre_reserved_capacity * stride, new_cap * stride
                )

        self._pre_reserved_capacity = new_cap

    def _grow_agg_slab_zero_filled[AggIdx: Int](
        mut self, old_bytes: Int, new_bytes: Int
    ):
        """Grow `_agg_slab_<AggIdx>` from `old_bytes` to `new_bytes` live
        bytes and zero-fill `[old_bytes, new_bytes)`."""
        comptime if AggIdx == 0:
            _grow_zero_filled(self._agg_slab_0, old_bytes, new_bytes)
        elif AggIdx == 1:
            _grow_zero_filled(self._agg_slab_1, old_bytes, new_bytes)
        elif AggIdx == 2:
            _grow_zero_filled(self._agg_slab_2, old_bytes, new_bytes)
        elif AggIdx == 3:
            _grow_zero_filled(self._agg_slab_3, old_bytes, new_bytes)
        elif AggIdx == 4:
            _grow_zero_filled(self._agg_slab_4, old_bytes, new_bytes)
        elif AggIdx == 5:
            _grow_zero_filled(self._agg_slab_5, old_bytes, new_bytes)
        elif AggIdx == 6:
            _grow_zero_filled(self._agg_slab_6, old_bytes, new_bytes)
        else:
            _grow_zero_filled(self._agg_slab_7, old_bytes, new_bytes)

    # -------------------------------------------------------------------
    # AggregatorWithStruct state: init, commit, combine, finalize
    # -------------------------------------------------------------------
    #
    # Each reads `_agg_slab_<AggIdx>` as an array of `Agg.StateStruct`
    # indexed by entry id. That is valid only when the storage was built
    # with `agg_state_strides_in[AggIdx] == Agg.STATE_BYTES ==
    # size_of[Agg.StateStruct]()`; the sinks build it so.

    def init_state_with_struct[
        AggIdx: Int, Agg: AggregatorWithStruct
    ](mut self, handle: EntryHandle):
        """Write `Agg.init()` into aggregate `AggIdx`'s state for the group
        `handle` names (call once, when the probe reports a new group)."""
        var inner_base = self._agg_slab_byte_base[AggIdx]().bitcast[
            Agg.StateStruct
        ]()
        var eid = Int(handle._entry_idx)
        # SAFETY: eid < _num_groups <= _pre_reserved_capacity.
        (inner_base + eid)[] = Agg.init()

    def commit_aggregator_with_struct[
        AggIdx: Int, Agg: AggregatorWithStruct
    ](
        mut self,
        entry_ids: Span[Int32, _],
        values: Span[UInt8, _],
        num_rows: Int,
    ) raises:
        """Fold `num_rows` values (`values` read as
        `Scalar[Agg.InputDType]`) into the states of the groups
        `entry_ids` names, through `Agg.update`.

        The state is updated in place through a `ref` into the slab, not
        copied out and back: for a 520-byte median state that copy would
        dominate the update.
        """
        var values_ptr = values.unsafe_ptr().bitcast[
            Scalar[Agg.InputDType]
        ]()
        if self._num_groups == 0:
            return
        var inner_base = self._agg_slab_byte_base[AggIdx]().bitcast[
            Agg.StateStruct
        ]()
        # SAFETY: every entry id came from a probe of this storage, so it
        # is < _num_groups; `values` holds num_rows inputs.
        for i in range(num_rows):
            var eid = Int(entry_ids[i])
            ref s = (inner_base + eid)[]
            Agg.update(s, (values_ptr + i)[])

    def commit_corr_aggregator_with_struct[
        AggIdx: Int,
    ](
        mut self,
        entry_ids: Span[Int32, _],
        x_values: Span[UInt8, _],
        y_values: Span[UInt8, _],
        num_rows: Int,
    ) raises:
        """Fold `num_rows` (x, y) Float64 pairs into the
        `CorrelationAggregator` states of the groups `entry_ids` names,
        through `update_bivariate`.

        `CorrelationAggregator` is the only two-input aggregate, so this is
        monomorphized on it directly rather than through a trait.

        SAFETY: `x_values` and `y_values` each hold `num_rows` Float64s.
        """
        var x_ptr = x_values.unsafe_ptr().bitcast[Scalar[DType.float64]]()
        var y_ptr = y_values.unsafe_ptr().bitcast[Scalar[DType.float64]]()
        if self._num_groups == 0:
            return
        var inner_base = self._agg_slab_byte_base[AggIdx]().bitcast[
            CorrelationAggregator.StateStruct
        ]()
        for i in range(num_rows):
            var eid = Int(entry_ids[i])
            var s = (inner_base + eid)[]
            CorrelationAggregator.update_bivariate(
                s, Float64((x_ptr + i)[]), Float64((y_ptr + i)[]),
            )
            (inner_base + eid)[] = s

    def combine_donor_keys_with_struct[
        *Ss: AggregatorWithStruct
    ](mut self, ref donor: Self) raises:
        """Merge every group of `donor` into self, one hash and probe per
        donor group.

        A donor key self lacks is inserted, and each of its states is copied
        in with one typed store (the donor's state is the merged state of a
        new group). A key self holds is merged with `Ss[ai].combine` per
        aggregate. `Ss` is the storage's aggregate pack, in AggIdx order.
        """
        var donor_n = donor._num_groups
        if donor_n == 0:
            return

        var donor_keys = donor._key_bytes._unsafe_ptr()
        for donor_eid in range(donor_n):
            var donor_key_ptr = donor_keys + donor_eid * donor._key_stride_bytes
            var h = _ck_hash_key_bytes(
                donor_key_ptr,
                donor._key_dtypes,
                donor._key_col_offsets,
                donor._key_col_widths,
                donor._num_key_cols,
            )
            var self_eid = self._lookup_multi_key(h, donor_key_ptr)
            if self_eid < 0:
                if self._num_groups + 1 > self._resize_threshold:
                    self._grow_and_rehash()
                self_eid = self._insert_new_multi_key(h, donor_key_ptr)
                if self_eid + 1 > self._pre_reserved_capacity:
                    self._ensure_pre_reserved_capacity(self_eid + 1)
                comptime for ai in range(Ss.__len__()):
                    comptime A = Ss[ai]
                    var donor_base = donor._agg_slab_byte_base[ai]().bitcast[
                        A.StateStruct
                    ]()
                    var self_base = self._agg_slab_byte_base[ai]().bitcast[
                        A.StateStruct
                    ]()
                    (self_base + self_eid)[] = (
                        (donor_base + donor_eid)[].copy()
                    )
            else:
                comptime for ai in range(Ss.__len__()):
                    comptime A = Ss[ai]
                    var donor_base = donor._agg_slab_byte_base[ai]().bitcast[
                        A.StateStruct
                    ]()
                    var self_base = self._agg_slab_byte_base[ai]().bitcast[
                        A.StateStruct
                    ]()
                    var s = (self_base + self_eid)[].copy()
                    A.combine(s, (donor_base + donor_eid)[].copy())
                    (self_base + self_eid)[] = s^

    def finalize_aggregator_with_struct[
        o: Origin[mut=True], //, AggIdx: Int, Agg: AggregatorWithStruct
    ](mut self, out_buf: Span[UInt8, o]) raises:
        """Write `Agg.finalize(state)` of every group, in entry-id order,
        into `out_buf` as `Scalar[Agg.OutputDType]`s. `out_buf` must hold
        `num_groups() * size_of[Scalar[Agg.OutputDType]]()` bytes."""
        var n_groups = self._num_groups
        if n_groups == 0:
            return
        var out_ptr = out_buf.unsafe_ptr().bitcast[
            Scalar[Agg.OutputDType]
        ]()
        var inner_base = self._agg_slab_byte_base[AggIdx]().bitcast[
            Agg.StateStruct
        ]()
        for i in range(n_groups):
            var s = (inner_base + i)[].copy()
            (out_ptr + i)[] = Agg.finalize(s^)

    # -------------------------------------------------------------------
    # Inspection
    # -------------------------------------------------------------------

    def num_groups(self) -> Int:
        """Number of distinct groups inserted so far."""
        return self._num_groups

    def capacity(self) -> Int:
        """Hash table slot count."""
        return self._capacity

    # -------------------------------------------------------------------
    # The composite-key table
    # -------------------------------------------------------------------

    def init_multi_key_mode(mut self, var key_dtypes: List[DType]) raises:
        """Set the key columns' DTypes (one to eight fixed-width columns,
        packed in order). Call after `__init__` and before any insert;
        raises once a group exists."""
        var n = len(key_dtypes)
        if n <= 0 or n > 8:
            raise Error(
                "SlabStorage.init_multi_key_mode: num_key_cols out of"
                " [1, 8]; got " + String(n)
            )
        if self._num_groups > 0:
            raise Error(
                "SlabStorage.init_multi_key_mode: cannot change the key"
                " shape after groups have been inserted"
                " (num_groups=" + String(self._num_groups) + ")"
            )
        for i in range(8):
            self._key_dtypes[i] = DType.int8
            self._key_col_offsets[i] = 0
            self._key_col_widths[i] = 0
        var stride = 0
        for i in range(n):
            var dt = key_dtypes[i]
            self._key_dtypes[i] = dt
            self._key_col_offsets[i] = stride
            var w = _ck_dtype_byte_width(dt)
            self._key_col_widths[i] = w
            stride += w
        self._num_key_cols = n
        self._key_stride_bytes = stride
        # Re-size `_key_bytes` for the new stride (the previous slab drops
        # on reassignment); in deferred mode the first insert allocates.
        var target_bytes = self._capacity * stride
        if target_bytes > 0:
            self._key_bytes = Slab[UInt8].create_prefilled(target_bytes)
        else:
            self._key_bytes = Slab[UInt8]()

    def probe_or_insert_multi_key(
        mut self, key: Span[UInt8, _]
    ) raises -> Tuple[EntryHandle, Bool]:
        """Find or insert the group of the packed key `key` (exactly the
        key stride in bytes). Returns (handle, was_new)."""
        if self._num_key_cols == 0:
            raise Error(
                "SlabStorage.probe_or_insert_multi_key: no key columns"
                " (call init_multi_key_mode first)"
            )
        _check_key_len(key, self._key_stride_bytes)
        var key_ptr = key.unsafe_ptr()
        if self._num_groups + 1 > self._resize_threshold:
            self._grow_and_rehash_multi_key()
        var h = _ck_hash_key_bytes(
            key_ptr,
            self._key_dtypes,
            self._key_col_offsets,
            self._key_col_widths,
            self._num_key_cols,
        )
        var found_eid = self._lookup_multi_key(h, key_ptr)
        if found_eid >= 0:
            return (EntryHandle(0, found_eid), False)
        var new_eid = self._insert_new_multi_key(h, key_ptr)
        return (EntryHandle(0, new_eid), True)

    def probe_or_insert_multi_key_with_hash(
        mut self, h: UInt64, key: Span[UInt8, _]
    ) raises -> Tuple[EntryHandle, Bool]:
        """`probe_or_insert_multi_key` with the hash supplied by the caller.

        `h` MUST equal the hash `_ck_hash_key_bytes` computes for `key`
        (`_fib_hash_1(key)` for one Int64 column); a different hash
        inserts a second group for a key already present.
        """
        if self._num_key_cols == 0:
            raise Error(
                "SlabStorage.probe_or_insert_multi_key_with_hash: no key"
                " columns (call init_multi_key_mode first)"
            )
        _check_key_len(key, self._key_stride_bytes)
        var key_ptr = key.unsafe_ptr()
        if self._num_groups + 1 > self._resize_threshold:
            self._grow_and_rehash_multi_key()
        var found_eid = self._lookup_multi_key(h, key_ptr)
        if found_eid >= 0:
            return (EntryHandle(0, found_eid), False)
        var new_eid = self._insert_new_multi_key(h, key_ptr)
        return (EntryHandle(0, new_eid), True)

    def probe_or_insert_2int64_with_hash(
        mut self, h: UInt64, k0: Int64, k1: Int64
    ) raises -> Tuple[EntryHandle, Bool]:
        """Find or insert the group of the (Int64, Int64) key (k0, k1),
        compared in registers rather than packed into a byte buffer.

        The storage MUST be in the two-Int64-column shape (stride 16), and
        `h` MUST equal `_fib_hash_2(k0, k1)`, the hash
        `_ck_hash_key_bytes` computes for the packed key.
        """
        if self._num_key_cols == 0:
            raise Error(
                "SlabStorage.probe_or_insert_2int64_with_hash: no key"
                " columns (call init_multi_key_mode first)"
            )
        if self._num_groups + 1 > self._resize_threshold:
            self._grow_and_rehash_multi_key()
        var found_eid = self._lookup_2int64(h, k0, k1)
        if found_eid >= 0:
            return (EntryHandle(0, found_eid), False)
        var new_eid = self._insert_new_2int64(h, k0, k1)
        return (EntryHandle(0, new_eid), True)

    def _lookup_2int64(self, h: UInt64, k0: Int64, k1: Int64) -> Int:
        """SIMD-16 fingerprint probe for the (Int64, Int64) key shape; the
        entry id of (k0, k1), or -1."""
        var fp = UInt8(h >> 56) | _FP_NONZERO_MASK
        var mask = self._capacity - 1
        var base_slot = (Int(h) & mask) & ~(_SIMD_GROUP - 1)
        var target_fp = SIMD[DType.uint8, _SIMD_GROUP](fp)
        var empty_fp = SIMD[DType.uint8, _SIMD_GROUP](_FP_EMPTY)
        var ht_base = self._ht_entries._unsafe_ptr().bitcast[UInt64]()
        var fp_base = self._fingerprints._unsafe_ptr()
        var keys_base_i64 = self._key_bytes._unsafe_ptr().bitcast[Int64]()
        for _ in range(self._capacity >> 4):
            var fp_vec = (fp_base + base_slot).load[width=_SIMD_GROUP]()
            var match_mask = fp_vec.eq(target_fp)
            var empty_mask = fp_vec.eq(empty_fp)
            for lane in range(_SIMD_GROUP):
                if match_mask[lane]:
                    var ht_val = (ht_base + base_slot + lane)[]
                    if ht_val != _HT_ENTRY_EMPTY:
                        var stored_eid = Int(ht_val) - 1
                        var lo_idx = stored_eid * 2
                        if (
                            (keys_base_i64 + lo_idx)[] == k0
                            and (keys_base_i64 + lo_idx + 1)[] == k1
                        ):
                            return stored_eid
            if Bool(empty_mask.cast[DType.uint8]().reduce_max()):
                return -1
            base_slot = (base_slot + _SIMD_GROUP) & mask
        return -1

    def _insert_new_2int64(
        mut self, h: UInt64, k0: Int64, k1: Int64
    ) raises -> Int:
        """Insert (k0, k1) as a new group; the caller has checked it is
        absent with `_lookup_2int64`."""
        var fp = UInt8(h >> 56) | _FP_NONZERO_MASK
        var found_slot = Self._ck_find_empty_slot(
            self._fingerprints._unsafe_ptr(), h, self._capacity
        )
        if found_slot < 0:
            raise Error("SlabStorage._insert_new_2int64: table full")
        var new_eid = self._num_groups
        self._grow_key_bytes((new_eid + 1) * 16, 16)
        var dst_i64 = (
            self._key_bytes._unsafe_ptr() + new_eid * 16
        ).bitcast[Int64]()
        dst_i64[] = k0
        (dst_i64 + 1)[] = k1
        (self._ht_entries._unsafe_ptr().bitcast[UInt64]() + found_slot)[] = (
            UInt64(new_eid) + 1
        )
        (self._fingerprints._unsafe_ptr() + found_slot)[] = fp
        self._num_groups = new_eid + 1
        return new_eid

    def _lookup_multi_key(
        self, h: UInt64, key_ptr: UnsafePointer[UInt8, _]
    ) -> Int:
        """SIMD-16 fingerprint probe; the entry id of the packed key at
        `key_ptr`, or -1. An 8-byte key compares as one Int64 and a 16-byte
        key as two; other strides compare byte by byte."""
        var fp = UInt8(h >> 56) | _FP_NONZERO_MASK
        var mask = self._capacity - 1
        var base_slot = (Int(h) & mask) & ~(_SIMD_GROUP - 1)
        var target_fp = SIMD[DType.uint8, _SIMD_GROUP](fp)
        var empty_fp = SIMD[DType.uint8, _SIMD_GROUP](_FP_EMPTY)
        var ht_base = self._ht_entries._unsafe_ptr().bitcast[UInt64]()
        var fp_base = self._fingerprints._unsafe_ptr()
        var keys_base = self._key_bytes._unsafe_ptr()
        var stride = self._key_stride_bytes
        var keys_base_i64 = keys_base.bitcast[Int64]()
        var probe_key_i64: Int64 = 0
        var probe_key_i64_lo: Int64 = 0
        var probe_key_i64_hi: Int64 = 0
        if stride == 8:
            probe_key_i64 = key_ptr.bitcast[Int64]()[]
        elif stride == 16:
            probe_key_i64_lo = key_ptr.bitcast[Int64]()[]
            probe_key_i64_hi = (key_ptr + 8).bitcast[Int64]()[]
        for _ in range(self._capacity >> 4):
            var fp_vec = (fp_base + base_slot).load[width=_SIMD_GROUP]()
            var match_mask = fp_vec.eq(target_fp)
            var empty_mask = fp_vec.eq(empty_fp)
            for lane in range(_SIMD_GROUP):
                if match_mask[lane]:
                    var ht_val = (ht_base + base_slot + lane)[]
                    if ht_val != _HT_ENTRY_EMPTY:
                        var stored_eid = Int(ht_val) - 1
                        if stride == 8:
                            keyeq_record(KEYEQ_SLAB_STRIDE8, 8, 8, True)
                            if (
                                (keys_base_i64 + stored_eid)[]
                                == probe_key_i64
                            ):
                                return stored_eid
                        elif stride == 16:
                            # Entry `i` is Int64 lanes [2i, 2i + 2).
                            var lo_idx = stored_eid * 2
                            keyeq_record(KEYEQ_SLAB_STRIDE16, 16, 16, True)
                            if (
                                (keys_base_i64 + lo_idx)[]
                                == probe_key_i64_lo
                                and (keys_base_i64 + lo_idx + 1)[]
                                == probe_key_i64_hi
                            ):
                                return stored_eid
                        else:
                            if _ck_memcmp_keys(
                                keys_base + stored_eid * stride,
                                key_ptr, stride,
                            ):
                                return stored_eid
            if Bool(empty_mask.cast[DType.uint8]().reduce_max()):
                return -1
            base_slot = (base_slot + _SIMD_GROUP) & mask
        return -1

    @staticmethod
    def _ck_find_empty_slot(
        fp_base: UnsafePointer[UInt8, _], h: UInt64, capacity: Int
    ) -> Int:
        """The first empty slot of the SIMD-16 group walk from `h`, or -1
        when no slot is empty (the caller raises)."""
        var mask = capacity - 1
        var base_slot = (Int(h) & mask) & ~(_SIMD_GROUP - 1)
        var empty_fp = SIMD[DType.uint8, _SIMD_GROUP](_FP_EMPTY)
        for _ in range(capacity >> 4):
            var fp_vec = (fp_base + base_slot).load[width=_SIMD_GROUP]()
            var empty_mask = fp_vec.eq(empty_fp)
            if Bool(empty_mask.cast[DType.uint8]().reduce_max()):
                for lane in range(_SIMD_GROUP):
                    if empty_mask[lane]:
                        return base_slot + lane
            base_slot = (base_slot + _SIMD_GROUP) & mask
        return -1

    def _grow_key_bytes(mut self, needed_bytes: Int, stride: Int):
        """Grow `_key_bytes` to at least `needed_bytes` live bytes by
        doubling (from 16 keys), zero-filling the new tail."""
        var current_bytes = len(self._key_bytes)
        if needed_bytes <= current_bytes:
            return
        var new_bytes = current_bytes
        if new_bytes == 0:
            new_bytes = stride * 16
        while new_bytes < needed_bytes:
            new_bytes = new_bytes * 2
        _grow_zero_filled(self._key_bytes, current_bytes, new_bytes)

    def _insert_new_multi_key(
        mut self, h: UInt64, key_ptr: UnsafePointer[UInt8, _]
    ) raises -> Int:
        """Insert the packed key at `key_ptr` as a new group; the caller has
        checked it is absent with `_lookup_multi_key`."""
        var fp = UInt8(h >> 56) | _FP_NONZERO_MASK
        var found_slot = Self._ck_find_empty_slot(
            self._fingerprints._unsafe_ptr(), h, self._capacity
        )
        if found_slot < 0:
            raise Error("SlabStorage._insert_new_multi_key: table full")
        var new_eid = self._num_groups
        var stride = self._key_stride_bytes
        self._grow_key_bytes((new_eid + 1) * stride, stride)
        # An 8- or 16-byte key is copied as one or two Int64 stores.
        # SAFETY: `_key_bytes` holds at least (new_eid + 1) * stride bytes.
        var dst = self._key_bytes._unsafe_ptr() + new_eid * stride
        if stride == 8:
            dst.bitcast[Int64]()[] = key_ptr.bitcast[Int64]()[]
        elif stride == 16:
            var dst_i64 = dst.bitcast[Int64]()
            dst_i64[] = key_ptr.bitcast[Int64]()[]
            (dst_i64 + 1)[] = (key_ptr + 8).bitcast[Int64]()[]
        else:
            for i in range(stride):
                (dst + i)[] = (key_ptr + i)[]
        (self._ht_entries._unsafe_ptr().bitcast[UInt64]() + found_slot)[] = (
            UInt64(new_eid) + 1
        )
        (self._fingerprints._unsafe_ptr() + found_slot)[] = fp
        self._num_groups = new_eid + 1
        return new_eid

    def _grow_and_rehash(mut self) raises:
        """Double the hash table and reinsert every group."""
        self._grow_and_rehash_multi_key()

    def _grow_and_rehash_multi_key(mut self) raises:
        """Double `_capacity` (or allocate `_SLAB_DEFAULT_INITIAL_CAPACITY`
        slots) and reinsert every group by rehashing its stored key bytes;
        then grow the state slabs to the new capacity."""
        var new_cap = self._capacity * 2
        if new_cap == 0:
            new_cap = _SLAB_DEFAULT_INITIAL_CAPACITY
        var new_ht = Slab[UInt8].create_prefilled(new_cap * 8)
        var new_fp = Slab[UInt8].create_prefilled(new_cap * 1)
        var new_ht_base = new_ht._unsafe_ptr().bitcast[UInt64]()
        var new_fp_base = new_fp._unsafe_ptr()
        var stride = self._key_stride_bytes
        var keys_base = self._key_bytes._unsafe_ptr()
        for eid in range(self._num_groups):
            var key_ptr = keys_base + eid * stride
            var h = _ck_hash_key_bytes(
                key_ptr, self._key_dtypes, self._key_col_offsets,
                self._key_col_widths, self._num_key_cols,
            )
            var fp = UInt8(h >> 56) | _FP_NONZERO_MASK
            var rehash_slot = Self._ck_find_empty_slot(
                new_fp_base, h, new_cap
            )
            (new_ht_base + rehash_slot)[] = UInt64(eid) + 1
            (new_fp_base + rehash_slot)[] = fp
        self._ht_entries = new_ht^
        self._fingerprints = new_fp^
        self._capacity = new_cap
        self._resize_threshold = (
            new_cap * _SLAB_LOAD_FACTOR_NUM // _SLAB_LOAD_FACTOR_DEN
        )
        # Keep every state slab sized to the table, so the commits never
        # grow a slab on the hot path.
        self._ensure_pre_reserved_capacity(new_cap)

    # -------------------------------------------------------------------
    # Key output
    # -------------------------------------------------------------------

    def finalize_keys_int64[
        o: Origin[mut=True], //
    ](ref self, out_buf: Span[UInt8, o]) raises:
        """Write every group's Int64 key, in entry-id order, into `out_buf`
        (at least `num_groups() * 8` bytes). One Int64 key column only."""
        self.finalize_keys_multi(out_buf)

    def finalize_keys_multi[
        o: Origin[mut=True], //
    ](ref self, out_buf: Span[UInt8, o]) raises:
        """Write every group's key, in entry-id order, into `out_buf` (at
        least `num_groups() * 8` bytes). Raises unless the key is a single
        8-byte column."""
        if self._num_key_cols == 0:
            raise Error(
                "SlabStorage.finalize_keys_multi: no key columns"
                " (call init_multi_key_mode first)"
            )
        if self._num_key_cols != 1 or self._key_col_widths[0] != 8:
            raise Error(
                "SlabStorage.finalize_keys_multi: supports only a single"
                " 8-byte key column; got num_cols="
                + String(self._num_key_cols)
                + ", width0=" + String(self._key_col_widths[0])
            )
        var n_groups = self._num_groups
        if n_groups == 0:
            return
        _check_key_len(out_buf, n_groups * 8, exact=False)
        var out_ptr = out_buf.unsafe_ptr().bitcast[Int64]()
        # SAFETY: `_key_bytes` holds at least n_groups * 8 bytes.
        var keys_i64 = self._key_bytes._unsafe_ptr().bitcast[Int64]()
        for i in range(n_groups):
            (out_ptr + i)[] = (keys_i64 + i)[]

    def finalize_keys_multi_2col[
        o0: Origin[mut=True], o1: Origin[mut=True], //
    ](
        ref self,
        out_buf_0: Span[UInt8, o0],
        out_buf_1: Span[UInt8, o1],
    ) raises:
        """Split every group's (Int64, Int64) key, in entry-id order, into
        k0 -> `out_buf_0` and k1 -> `out_buf_1` (each at least
        `num_groups() * 8` bytes). Raises unless the key is two 8-byte
        columns."""
        if self._num_key_cols == 0:
            raise Error(
                "SlabStorage.finalize_keys_multi_2col: no key columns"
                " (call init_multi_key_mode first)"
            )
        if (
            self._num_key_cols != 2
            or self._key_col_widths[0] != 8
            or self._key_col_widths[1] != 8
        ):
            raise Error(
                "SlabStorage.finalize_keys_multi_2col: requires"
                " num_cols=2, width0=width1=8; got num_cols="
                + String(self._num_key_cols)
                + ", width0=" + String(self._key_col_widths[0])
                + ", width1=" + String(self._key_col_widths[1])
            )
        var n_groups = self._num_groups
        if n_groups == 0:
            return
        _check_key_len(out_buf_0, n_groups * 8, exact=False)
        _check_key_len(out_buf_1, n_groups * 8, exact=False)
        var out0_ptr = out_buf_0.unsafe_ptr().bitcast[Int64]()
        var out1_ptr = out_buf_1.unsafe_ptr().bitcast[Int64]()
        # SAFETY: `_key_bytes` holds at least n_groups * 16 bytes; group i
        # is k0 at Int64 lane 2i and k1 at lane 2i + 1.
        var keys_i64 = self._key_bytes._unsafe_ptr().bitcast[Int64]()
        for i in range(n_groups):
            (out0_ptr + i)[] = (keys_i64 + 2 * i)[]
            (out1_ptr + i)[] = (keys_i64 + 2 * i + 1)[]


# -----------------------------------------------------------------------------
# Module helpers
# -----------------------------------------------------------------------------


def _prefilled_agg_slab(
    capacity: Int, strides: List[Int], agg_idx: Int
) -> Slab[UInt8]:
    """A zero-filled slab of `capacity` states of aggregate `agg_idx`, or an
    empty slab when the storage has no aggregate `agg_idx`."""
    if agg_idx >= len(strides):
        return Slab[UInt8]()
    return Slab[UInt8].create_prefilled(capacity * strides[agg_idx])


def _grow_zero_filled(mut slab: Slab[UInt8], old_bytes: Int, new_bytes: Int):
    """Grow `slab` from `old_bytes` to `new_bytes` live bytes and zero
    `[old_bytes, new_bytes)`. A no-op when `new_bytes <= old_bytes`."""
    if new_bytes <= old_bytes:
        return
    slab.reserve(new_bytes - old_bytes)
    # UInt8 has no destructor, so exposing the reserved bytes before they
    # are written is sound; they are zeroed at once.
    slab.set_len_unchecked(new_bytes)
    var base = slab._unsafe_ptr()
    for off in range(old_bytes, new_bytes):
        (base + off)[] = UInt8(0)


@always_inline
def _check_key_len(buf: Span[UInt8, _], want: Int, exact: Bool = True) raises:
    """Raise when `buf` is shorter than `want` bytes (or, with `exact`, of
    any other length): a short span would be read or written past its
    end."""
    if len(buf) < want or (exact and len(buf) != want):
        raise Error(
            "SlabStorage: span of " + String(len(buf))
            + " bytes where " + String(want) + " are required"
        )
