# =============================================================================
# join_multi_key_builder -- `MultiKeyHashJoinBuilder`, the composite-key hash
# join's build side, with its INNER and LEFT probes.
# =============================================================================
#
# EQUALITY ARMS. A probe resolves, per key and once per call, how a candidate
# is compared: `Int32 ==` on dictionary indices when both sides carry the same
# dictionary (equal fingerprints), byte equality when both carry strings, else
# `Int64 ==` on the key slots. `mk_uniform_arm` collapses the per-key vector so
# a call whose keys all take one arm runs a uniform key loop; `MK_ARM_MIXED`
# runs the general per-key body. Each uniform body is a copy of one arm of the
# general body, so the arm cannot change an answer.
# =============================================================================

from std.memory import UnsafePointer

from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.string_array import StringArray
from komira_arrow.dictionary_array import StringDictionaryArray
from komira_collections.slab import Slab
from komira_dynamic_filter.bloom_filter import BloomFilter
from komira_buffer.heap_region import HeapRegion

from .join_multi_key import (
    MAX_JOIN_KEYS,
    MK_ARM_DICT,
    MK_ARM_INT,
    MK_ARM_MIXED,
    MK_ARM_STRING,
    MultiKeyColumns,
    _CHAIN_END,
    _FIB_HASH_CONST,
    _NAN_SENTINEL_BITS,
    _composite_hash_int64,
    _string_bytes_equal,
    _null_ptr,
    mk_uniform_arm,
)


struct MultiKeyHashJoinBuilder(Movable):
    """The build side of a composite-key hash join: N key columns (1 to
    `MAX_JOIN_KEYS`) of any type `extract_join_key_columns_typed` renders.

    Separate chaining: `_hash_table` maps a bucket to its chain head and
    `_next_chain[i]` links build row i to the next row of its chain
    (`_CHAIN_END` ends a chain). The entry space is ROW-INDEXED: entry i IS
    build row i, for every row, so a chain walk reads the build keys at the
    entry index directly and `num_rows()` (`len(_next_chain)`) is the full
    build extent the RIGHT / FULL unmatched sweep must cover. A row with a
    NULL key still takes its entry but is linked from no bucket, so it matches
    nothing. `_bloom` holds the composite hash of every inserted row;
    `_num_inserted` counts them (the chain-reachable rows), for output sizing.
    """

    var _build_keys: Slab[PrimitiveArray[DType.int64]]
    var _build_string_keys: Slab[Optional[StringArray[HeapRegion]]]
    var _build_dict_keys: Slab[Optional[StringDictionaryArray]]
    var _build_dict_fingerprints: List[UInt64]
    var _num_keys: Int
    var _hash_table: List[Int]
    var _next_chain: List[Int]
    var _capacity: Int
    var _bloom: BloomFilter
    var _num_inserted: Int

    def __init__(
        out self,
        var keys_bundle: MultiKeyColumns,
        var hash_table: List[Int],
        var next_chain: List[Int],
        capacity: Int,
        var bloom: BloomFilter,
        num_inserted: Int,
    ):
        self._num_keys = keys_bundle.num_keys
        self._build_keys = keys_bundle.int_keys.take()
        self._build_string_keys = keys_bundle.string_keys.take()
        self._build_dict_keys = keys_bundle.dict_keys.take()
        self._build_dict_fingerprints = keys_bundle.dict_fingerprints.take()
        self._hash_table = hash_table^
        self._next_chain = next_chain^
        self._capacity = capacity
        self._bloom = bloom^
        self._num_inserted = num_inserted

    @staticmethod
    def build(
        var keys: MultiKeyColumns,
    ) raises -> MultiKeyHashJoinBuilder:
        """Build the index over the N build-side key columns in `keys`.

        Capacity is the power of two at or above 1.4 x rows (at least 16);
        insertion is LIFO (a new row becomes its bucket's chain head). Raises
        if the entry space is not row-indexed at the end, rather than let a
        RIGHT / FULL join drop preserved rows.

        Args:
            keys: N parallel build-side key columns (Slab — non-Copyable
                element type, taken by value and stored in the builder).
                All must share the same length. 1 <= N <= MAX_JOIN_KEYS.

        Returns:
            A MultiKeyHashJoinBuilder ready for probe_* calls.
        """
        var n_keys = keys.num_keys
        if n_keys < 1:
            raise Error(
                "MultiKeyHashJoinBuilder.build: at least one key column required"
            )
        if n_keys > MAX_JOIN_KEYS:
            raise Error(
                "MultiKeyHashJoinBuilder.build: too many key columns (got "
                + String(n_keys)
                + ", max "
                + String(MAX_JOIN_KEYS)
                + ")"
            )
        var n = keys.int_keys.value()[0].length
        for k in range(1, n_keys):
            if keys.int_keys.value()[k].length != n:
                raise Error(
                    "MultiKeyHashJoinBuilder.build: key column "
                    + String(k)
                    + " has length "
                    + String(keys.int_keys.value()[k].length)
                    + ", expected "
                    + String(n)
                )

        var min_cap = max(Int(Float64(n) * 1.4) + 1, 16)
        var cap = 1
        while cap < min_cap:
            cap *= 2
        var ht = List[Int]()
        ht.resize(cap, _CHAIN_END)

        var next_chain = List[Int](capacity=n)
        var bloom = BloomFilter.with_ndv_fpp(max(n, 1), 0.01)

        var mask = UInt64(cap - 1)

        var key_buf = List[Int64](capacity=n_keys)
        for _ in range(n_keys):
            key_buf.append(Int64(0))

        var ht_ptr = ht.unsafe_ptr()

        # SAFETY: one pointer per key column, carrying the origin of the
        # key Slab (`ko`). `keys` is owned by this frame until it moves into
        # the returned builder AFTER the loop, so every pointer outlives the
        # loop; the keepalive `_ = build_ptrs` below pins that order. The
        # `unsafe_origin_cast[ko]` re-tags each view's pointer with the
        # Slab's origin so they fit one `List`.
        comptime ko = origin_of(keys.int_keys.value())
        var build_ptrs = List[UnsafePointer[Scalar[DType.int64], ko]]()
        for k in range(n_keys):
            ref kref = keys.int_keys.value()[k]
            build_ptrs.append(
                kref.view_ro()
                    ._unsafe_ptr()
                    .bitcast[Scalar[DType.int64]]()
                    .unsafe_mut_cast[ko.mut]()
                    .unsafe_origin_cast[ko]()
            )
            _ = kref  # keepalive for src

        var num_inserted = 0
        for i in range(n):
            var has_nan = False
            for k in range(n_keys):
                var v = Int64((build_ptrs[k] + i)[])
                if v == _NAN_SENTINEL_BITS:
                    has_nan = True
                    break
                key_buf[k] = v
            if has_nan:
                next_chain.append(_CHAIN_END)
                continue

            var key_buf_ptr = key_buf.unsafe_ptr()
            var h = _composite_hash_int64(key_buf_ptr, n_keys)
            var slot = Int(h & mask)

            var old_head = (ht_ptr + slot)[]
            next_chain.append(old_head)
            (ht_ptr + slot)[] = i
            num_inserted += 1

            bloom.insert_hash(h)

        if len(next_chain) != n:
            raise Error(
                "MultiKeyHashJoinBuilder.build: entry space is not row-indexed"
                " (next_chain="
                + String(len(next_chain))
                + ", build rows="
                + String(n)
                + ") — RIGHT/FULL would silently drop preserved-side rows"
            )

        _ = ht
        _ = key_buf
        _ = build_ptrs  # ensure pointers outlive the build loop

        return MultiKeyHashJoinBuilder(
            keys_bundle=keys^,
            hash_table=ht^,
            next_chain=next_chain^,
            capacity=cap,
            bloom=bloom^,
            num_inserted=num_inserted,
        )

    @always_inline
    def num_keys(self) -> Int:
        return self._num_keys

    @always_inline
    def num_rows(self) -> Int:
        """Total build-side rows, INCLUDING sentinel-keyed (never-inserted) ones."""
        return len(self._next_chain)


    @always_inline
    def _row_keys_equal(
        self,
        chain_idx: Int,
        probe_buf: List[Int64],
    ) raises -> Bool:
        """Compare N build-side keys at row chain_idx against probe_buf."""
        for k in range(self._num_keys):
            ref kref = self._build_keys[k]
            var kref_view = kref.view_ro()
            var src = kref_view._unsafe_ptr().bitcast[Scalar[DType.int64]]()
            if Int64(src[chain_idx]) != probe_buf[k]:
                _ = kref
                return False
            _ = kref
        return True


    def probe_inner_into(
        self,
        probe_keys: MultiKeyColumns,
        mut build_matches: List[Int],
        mut probe_matches: List[Int],
    ) raises:
        """Inner join probe: emit (build_idx, probe_idx) per match, probe rows
        in order and each row's matches in chain order. A probe row with a
        NULL key, or whose hash the bloom rejects, is skipped.

        Args:
            probe_keys: N probe-side key columns (must match build-side
                key count). STRING keys carry FNV-1a hash bits in
                `int_keys[k]` plus the raw StringArray in
                `string_keys[k].value()` for byte-by-byte equality.
            build_matches: Appended (build-side row idx per match).
            probe_matches: Appended (probe-side row idx per match).
        """
        var n_keys = self._num_keys
        if probe_keys.num_keys != n_keys:
            raise Error(
                "MultiKeyHashJoinBuilder.probe_inner_into: probe key count "
                + String(probe_keys.num_keys)
                + " != build key count "
                + String(n_keys)
            )
        var n = probe_keys.int_keys.value()[0].length
        for k in range(1, n_keys):
            if probe_keys.int_keys.value()[k].length != n:
                raise Error(
                    "MultiKeyHashJoinBuilder.probe_inner_into: probe key "
                    + String(k)
                    + " length "
                    + String(probe_keys.int_keys.value()[k].length)
                    + " != probe key 0 length "
                    + String(n)
                )

        var mask = UInt64(self._capacity - 1)

        # SAFETY: per-key probe and build pointers, each re-tagged with the
        # origin of the container it was read from (`probe_keys`' Slabs, the
        # builder's fields). Both are borrowed for the whole call, so every
        # pointer outlives the loop; the keepalives at the end pin that.
        # The pointers never leave this function.
        comptime po = origin_of(probe_keys.int_keys.value())
        comptime bo = origin_of(self._build_keys)
        comptime pso = origin_of(probe_keys.string_keys.value())
        comptime bso = origin_of(self._build_string_keys)
        comptime pdo = origin_of(probe_keys.dict_keys.value())
        comptime bdo = origin_of(self._build_dict_keys)
        var probe_ptrs = List[UnsafePointer[Scalar[DType.int64], po]]()
        var build_ptrs = List[UnsafePointer[Scalar[DType.int64], bo]]()
        var is_string = List[Bool]()
        var p_str_offs = List[UnsafePointer[Scalar[DType.int32], pso]]()
        var p_str_data = List[UnsafePointer[Scalar[DType.uint8], pso]]()
        var b_str_offs = List[UnsafePointer[Scalar[DType.int32], bso]]()
        var b_str_data = List[UnsafePointer[Scalar[DType.uint8], bso]]()
        var is_same_dict = List[Bool]()
        var p_dict_idx = List[UnsafePointer[Scalar[DType.int32], pdo]]()
        var b_dict_idx = List[UnsafePointer[Scalar[DType.int32], bdo]]()
        for k in range(n_keys):
            ref pref = probe_keys.int_keys.value()[k]
            probe_ptrs.append(
                pref.view_ro()
                    ._unsafe_ptr()
                    .bitcast[Scalar[DType.int64]]()
                    .unsafe_mut_cast[po.mut]()
                    .unsafe_origin_cast[po]()
            )
            _ = pref
            ref bref = self._build_keys[k]
            build_ptrs.append(
                bref.view_ro()
                    ._unsafe_ptr()
                    .bitcast[Scalar[DType.int64]]()
                    .unsafe_mut_cast[bo.mut]()
                    .unsafe_origin_cast[bo]()
            )
            _ = bref
            ref pstr_slot = probe_keys.string_keys.value()[k]
            ref bstr_slot = self._build_string_keys[k]
            if pstr_slot.__bool__() and bstr_slot.__bool__():
                is_string.append(True)
                ref pstr = pstr_slot.value()
                p_str_offs.append(
                    pstr.offsets.view_ro()
                        ._unsafe_ptr()
                        .bitcast[Scalar[DType.int32]]()
                        .unsafe_mut_cast[pso.mut]()
                        .unsafe_origin_cast[pso]()
                )
                p_str_data.append(
                    pstr.data.view_ro()
                        ._unsafe_ptr()
                        .bitcast[Scalar[DType.uint8]]()
                        .unsafe_mut_cast[pso.mut]()
                        .unsafe_origin_cast[pso]()
                )
                _ = pstr
                ref bstr = bstr_slot.value()
                b_str_offs.append(
                    bstr.offsets.view_ro()
                        ._unsafe_ptr()
                        .bitcast[Scalar[DType.int32]]()
                        .unsafe_mut_cast[bso.mut]()
                        .unsafe_origin_cast[bso]()
                )
                b_str_data.append(
                    bstr.data.view_ro()
                        ._unsafe_ptr()
                        .bitcast[Scalar[DType.uint8]]()
                        .unsafe_mut_cast[bso.mut]()
                        .unsafe_origin_cast[bso]()
                )
                _ = bstr
            else:
                is_string.append(False)
                p_str_offs.append(_null_ptr[Scalar[DType.int32], pso]())
                p_str_data.append(_null_ptr[Scalar[DType.uint8], pso]())
                b_str_offs.append(_null_ptr[Scalar[DType.int32], bso]())
                b_str_data.append(_null_ptr[Scalar[DType.uint8], bso]())
            _ = pstr_slot
            _ = bstr_slot
            ref pdict_slot = probe_keys.dict_keys.value()[k]
            ref bdict_slot = self._build_dict_keys[k]
            var same_dict = False
            if pdict_slot.__bool__() and bdict_slot.__bool__():
                var p_fp = probe_keys.dict_fingerprints.value()[k]
                var b_fp = self._build_dict_fingerprints[k]
                if p_fp == b_fp:
                    same_dict = True
            is_same_dict.append(same_dict)
            if same_dict:
                ref pdict = pdict_slot.value()
                p_dict_idx.append(
                    pdict.indices.view_ro()
                        ._unsafe_ptr()
                        .bitcast[Scalar[DType.int32]]()
                        .unsafe_mut_cast[pdo.mut]()
                        .unsafe_origin_cast[pdo]()
                )
                _ = pdict
                ref bdict = bdict_slot.value()
                b_dict_idx.append(
                    bdict.indices.view_ro()
                        ._unsafe_ptr()
                        .bitcast[Scalar[DType.int32]]()
                        .unsafe_mut_cast[bdo.mut]()
                        .unsafe_origin_cast[bdo]()
                )
                _ = bdict
            else:
                p_dict_idx.append(_null_ptr[Scalar[DType.int32], pdo]())
                b_dict_idx.append(_null_ptr[Scalar[DType.int32], bdo]())
            _ = pdict_slot
            _ = bdict_slot

        var _arm_u = mk_uniform_arm(is_same_dict, is_string, n_keys)
        var ht_ptr = self._hash_table.unsafe_ptr()
        var nc_ptr = self._next_chain.unsafe_ptr()

        var probe_buf = List[Int64](capacity=n_keys)
        for _ in range(n_keys):
            probe_buf.append(Int64(0))
        var probe_buf_ptr = probe_buf.unsafe_ptr()

        for probe_idx in range(n):
            var has_nan = False
            for k in range(n_keys):
                var v = Int64((probe_ptrs[k] + probe_idx)[])
                if v == _NAN_SENTINEL_BITS:
                    has_nan = True
                    break
                probe_buf[k] = v
            if has_nan:
                continue

            var h = _composite_hash_int64(probe_buf_ptr, n_keys)

            if not self._bloom.check_hash(h):
                continue

            var slot = Int(h & mask)
            var chain_idx = (ht_ptr + slot)[]
            while chain_idx != _CHAIN_END:
                var brow = chain_idx
                var matched = True
                if _arm_u == MK_ARM_INT:
                    for k in range(n_keys):
                        if Int64((build_ptrs[k] + brow)[]) != probe_buf[k]:
                            matched = False
                            break
                elif _arm_u == MK_ARM_STRING:
                    for k in range(n_keys):
                        if not _string_bytes_equal(
                            p_str_offs[k], p_str_data[k], probe_idx,
                            b_str_offs[k], b_str_data[k], brow,
                        ):
                            matched = False
                            break
                elif _arm_u == MK_ARM_DICT:
                    for k in range(n_keys):
                        if (p_dict_idx[k] + probe_idx)[] != (b_dict_idx[k] + brow)[]:
                            matched = False
                            break
                else:
                    for k in range(n_keys):
                        if is_same_dict[k]:
                            if (p_dict_idx[k] + probe_idx)[] != (b_dict_idx[k] + brow)[]:
                                matched = False
                                break
                        elif is_string[k]:
                            if not _string_bytes_equal(
                                p_str_offs[k], p_str_data[k], probe_idx,
                                b_str_offs[k], b_str_data[k], brow,
                            ):
                                matched = False
                                break
                        else:
                            if Int64((build_ptrs[k] + brow)[]) != probe_buf[k]:
                                matched = False
                                break
                if matched:
                    build_matches.append(brow)
                    probe_matches.append(probe_idx)
                chain_idx = (nc_ptr + chain_idx)[]

        _ = self._hash_table
        _ = self._next_chain
        _ = probe_buf
        _ = probe_ptrs
        _ = build_ptrs
        _ = p_str_offs
        _ = p_str_data
        _ = b_str_offs
        _ = b_str_data
        _ = is_string
        _ = p_dict_idx
        _ = b_dict_idx
        _ = is_same_dict

    def probe_left_into(
        self,
        probe_keys: MultiKeyColumns,
        mut build_matches: List[Int],
        mut probe_matches: List[Int],
    ) raises:
        """Left outer join probe: emit `(build_idx, probe_idx)` per match and
        `(-1, probe_idx)` for a probe row with no match (a NULL key included)."""
        var n_keys = self._num_keys
        if probe_keys.num_keys != n_keys:
            raise Error(
                "MultiKeyHashJoinBuilder.probe_left_into: probe key count "
                + String(probe_keys.num_keys)
                + " != build key count "
                + String(n_keys)
            )
        var n = probe_keys.int_keys.value()[0].length
        var mask = UInt64(self._capacity - 1)

        # SAFETY: as in `probe_inner_into`.
        comptime po = origin_of(probe_keys.int_keys.value())
        comptime bo = origin_of(self._build_keys)
        comptime pso = origin_of(probe_keys.string_keys.value())
        comptime bso = origin_of(self._build_string_keys)
        comptime pdo = origin_of(probe_keys.dict_keys.value())
        comptime bdo = origin_of(self._build_dict_keys)
        var probe_ptrs = List[UnsafePointer[Scalar[DType.int64], po]]()
        var build_ptrs = List[UnsafePointer[Scalar[DType.int64], bo]]()
        var is_string = List[Bool]()
        var p_str_offs = List[UnsafePointer[Scalar[DType.int32], pso]]()
        var p_str_data = List[UnsafePointer[Scalar[DType.uint8], pso]]()
        var b_str_offs = List[UnsafePointer[Scalar[DType.int32], bso]]()
        var b_str_data = List[UnsafePointer[Scalar[DType.uint8], bso]]()
        var is_same_dict = List[Bool]()
        var p_dict_idx = List[UnsafePointer[Scalar[DType.int32], pdo]]()
        var b_dict_idx = List[UnsafePointer[Scalar[DType.int32], bdo]]()
        for k in range(n_keys):
            ref pref = probe_keys.int_keys.value()[k]
            probe_ptrs.append(
                pref.view_ro()
                    ._unsafe_ptr()
                    .bitcast[Scalar[DType.int64]]()
                    .unsafe_mut_cast[po.mut]()
                    .unsafe_origin_cast[po]()
            )
            _ = pref
            ref bref = self._build_keys[k]
            build_ptrs.append(
                bref.view_ro()
                    ._unsafe_ptr()
                    .bitcast[Scalar[DType.int64]]()
                    .unsafe_mut_cast[bo.mut]()
                    .unsafe_origin_cast[bo]()
            )
            _ = bref
            ref pstr_slot = probe_keys.string_keys.value()[k]
            ref bstr_slot = self._build_string_keys[k]
            if pstr_slot.__bool__() and bstr_slot.__bool__():
                is_string.append(True)
                ref pstr = pstr_slot.value()
                p_str_offs.append(
                    pstr.offsets.view_ro()
                        ._unsafe_ptr()
                        .bitcast[Scalar[DType.int32]]()
                        .unsafe_mut_cast[pso.mut]()
                        .unsafe_origin_cast[pso]()
                )
                p_str_data.append(
                    pstr.data.view_ro()
                        ._unsafe_ptr()
                        .bitcast[Scalar[DType.uint8]]()
                        .unsafe_mut_cast[pso.mut]()
                        .unsafe_origin_cast[pso]()
                )
                _ = pstr
                ref bstr = bstr_slot.value()
                b_str_offs.append(
                    bstr.offsets.view_ro()
                        ._unsafe_ptr()
                        .bitcast[Scalar[DType.int32]]()
                        .unsafe_mut_cast[bso.mut]()
                        .unsafe_origin_cast[bso]()
                )
                b_str_data.append(
                    bstr.data.view_ro()
                        ._unsafe_ptr()
                        .bitcast[Scalar[DType.uint8]]()
                        .unsafe_mut_cast[bso.mut]()
                        .unsafe_origin_cast[bso]()
                )
                _ = bstr
            else:
                is_string.append(False)
                p_str_offs.append(_null_ptr[Scalar[DType.int32], pso]())
                p_str_data.append(_null_ptr[Scalar[DType.uint8], pso]())
                b_str_offs.append(_null_ptr[Scalar[DType.int32], bso]())
                b_str_data.append(_null_ptr[Scalar[DType.uint8], bso]())
            _ = pstr_slot
            _ = bstr_slot
            ref pdict_slot = probe_keys.dict_keys.value()[k]
            ref bdict_slot = self._build_dict_keys[k]
            var same_dict = False
            if pdict_slot.__bool__() and bdict_slot.__bool__():
                if probe_keys.dict_fingerprints.value()[k] == self._build_dict_fingerprints[k]:
                    same_dict = True
            is_same_dict.append(same_dict)
            if same_dict:
                ref pdict = pdict_slot.value()
                p_dict_idx.append(
                    pdict.indices.view_ro()
                        ._unsafe_ptr()
                        .bitcast[Scalar[DType.int32]]()
                        .unsafe_mut_cast[pdo.mut]()
                        .unsafe_origin_cast[pdo]()
                )
                _ = pdict
                ref bdict = bdict_slot.value()
                b_dict_idx.append(
                    bdict.indices.view_ro()
                        ._unsafe_ptr()
                        .bitcast[Scalar[DType.int32]]()
                        .unsafe_mut_cast[bdo.mut]()
                        .unsafe_origin_cast[bdo]()
                )
                _ = bdict
            else:
                p_dict_idx.append(_null_ptr[Scalar[DType.int32], pdo]())
                b_dict_idx.append(_null_ptr[Scalar[DType.int32], bdo]())
            _ = pdict_slot
            _ = bdict_slot

        var _arm_u = mk_uniform_arm(is_same_dict, is_string, n_keys)
        var ht_ptr = self._hash_table.unsafe_ptr()
        var nc_ptr = self._next_chain.unsafe_ptr()

        var probe_buf = List[Int64](capacity=n_keys)
        for _ in range(n_keys):
            probe_buf.append(Int64(0))
        var probe_buf_ptr = probe_buf.unsafe_ptr()

        for probe_idx in range(n):
            var has_nan = False
            for k in range(n_keys):
                var v = Int64((probe_ptrs[k] + probe_idx)[])
                if v == _NAN_SENTINEL_BITS:
                    has_nan = True
                    break
                probe_buf[k] = v
            if has_nan:
                build_matches.append(-1)
                probe_matches.append(probe_idx)
                continue

            var h = _composite_hash_int64(probe_buf_ptr, n_keys)
            var slot = Int(h & mask)
            var chain_idx = (ht_ptr + slot)[]
            var found = False
            while chain_idx != _CHAIN_END:
                var brow = chain_idx
                var matched = True
                if _arm_u == MK_ARM_INT:
                    for k in range(n_keys):
                        if Int64((build_ptrs[k] + brow)[]) != probe_buf[k]:
                            matched = False
                            break
                elif _arm_u == MK_ARM_STRING:
                    for k in range(n_keys):
                        if not _string_bytes_equal(
                            p_str_offs[k], p_str_data[k], probe_idx,
                            b_str_offs[k], b_str_data[k], brow,
                        ):
                            matched = False
                            break
                elif _arm_u == MK_ARM_DICT:
                    for k in range(n_keys):
                        if (p_dict_idx[k] + probe_idx)[] != (b_dict_idx[k] + brow)[]:
                            matched = False
                            break
                else:
                    for k in range(n_keys):
                        if is_same_dict[k]:
                            if (p_dict_idx[k] + probe_idx)[] != (b_dict_idx[k] + brow)[]:
                                matched = False
                                break
                        elif is_string[k]:
                            if not _string_bytes_equal(
                                p_str_offs[k], p_str_data[k], probe_idx,
                                b_str_offs[k], b_str_data[k], brow,
                            ):
                                matched = False
                                break
                        else:
                            if Int64((build_ptrs[k] + brow)[]) != probe_buf[k]:
                                matched = False
                                break
                if matched:
                    build_matches.append(brow)
                    probe_matches.append(probe_idx)
                    found = True
                chain_idx = (nc_ptr + chain_idx)[]
            if not found:
                build_matches.append(-1)
                probe_matches.append(probe_idx)

        _ = self._hash_table
        _ = self._next_chain
        _ = probe_buf
        _ = probe_ptrs
        _ = build_ptrs
        _ = p_str_offs
        _ = p_str_data
        _ = b_str_offs
        _ = b_str_data
        _ = is_string
        _ = p_dict_idx
        _ = b_dict_idx
        _ = is_same_dict
