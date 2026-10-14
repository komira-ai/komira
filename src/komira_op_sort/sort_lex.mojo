# =============================================================================
# Single-pass lexicographic multi-key sort of a RecordBatch
# =============================================================================
#
# `sort_batch_by_keys` (sort_multi.mojo) implements multi-column sort via K
# stable single-column passes — each pass does `Column.as_primitive` (a deep
# copy of the key buffer), a full O(N log N) sort, then a full-batch gather.
# For a 4-key sort over even a modest batch that is 4× the gather cost + 4
# separate sort allocations + 2 string merge sorts (memcmp per comparison).
#
# This module replaces those K passes with ONE pass when every sort key is a
# type we can encode into a monotone Int64 "rank":
#   * INT32 / INT64                         — read the value (sign-extended).
#   * STRING                                — dict the distinct values, sort
#     the distinct list lexicographically, map each row to its sorted-rank.
#     Comparing ranks is then equivalent to comparing the strings.
#   * DICTIONARY                            — decode the dictionary to strings,
#     sort, build dict_index -> sorted_rank, map each row.
#
# FLOAT64 / LARGE_STRING / BINARY keys are NOT handled here — the caller
# (`sort_batch_by_keys`) keeps the K-pass path for those.
#
# The K rank arrays are written into ONE contiguous row-major buffer
# `enc_flat[k * num_rows + row]`; the rows are sorted by a single stable merge
# sort over an index permutation, comparing the rank rows lexicographically
# with the per-key descending flag applied. A single gather produces the
# output.
#
# Output is byte-identical to the K-pass `sort_batch_by_keys` for the
# supported key types (same lexicographic order, same stable tie-break).
# =============================================================================

from std.memory import alloc, memcpy

from komira_counters.keyeq_census import keyeq_record, KEYEQ_SORTLEX_VERIFY

from komira_arrow.record_batch import RecordBatch
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.arrow_types import ArrowType
from komira_column_kernels.compiler_helpers import gather_batch_by_sort_indices
from komira_buffer.heap_region import HeapRegion
from .sort_radix import radix_sort_int64


comptime _INSERTION_SORT_THRESHOLD: Int = 32


def lex_sort_supported_key(at: ArrowType) -> Bool:
    """Return True iff a key column of this type can be lex-sorted in one pass.

    INT32 / INT64 are read directly; STRING / DICTIONARY are dict-rank
    encoded. Everything else (FLOAT64, LARGE_STRING, BINARY, ...) is left to
    the K-pass `sort_batch_by_keys` fallback.
    """
    return (
        at == ArrowType.INT64
        or at == ArrowType.INT32
        or at == ArrowType.STRING
        or at == ArrowType.DICTIONARY
    )


# -----------------------------------------------------------------------------
# Per-key rank encoding
# -----------------------------------------------------------------------------


@always_inline
def _str_lt(a: String, b: String) -> Bool:
    """Byte-wise lexicographic `a < b` with length tie-break (shorter prefix
    sorts first). Matches the STRING sort kernel's comparator semantics."""
    var ab = a.as_bytes()
    var bb = b.as_bytes()
    var an = len(ab)
    var bn = len(bb)
    var m = an if an < bn else bn
    var i = 0
    while i < m:
        var ca = ab[i]
        var cb = bb[i]
        if ca != cb:
            return ca < cb
        i += 1
    return an < bn


def _sorted_perm_from_distinct(distinct: List[String]) raises -> List[Int]:
    """Return `perm` such that `perm[provisional_id]` is the rank of that
    distinct value in lexicographic order. `distinct[provisional_id]` is the
    string for that provisional id (the order it was first seen)."""
    var d = len(distinct)
    var perm = List[Int](capacity=max(d, 1))
    for _ in range(d):
        perm.append(0)
    if d <= 1:
        return perm^
    var order = List[Int](capacity=d)
    for i in range(d):
        order.append(i)
    # `d` (number of distinct values in a sort-key column) is tiny in practice
    # — insertion sort keeps the implementation small.
    for i in range(1, d):
        var v = order[i]
        var j = i
        while j > 0 and _str_lt(distinct[v], distinct[order[j - 1]]):
            order[j] = order[j - 1]
            j -= 1
        order[j] = v
    for rank in range(d):
        perm[order[rank]] = rank
    return perm^


def _encode_int_key[
    o_enc: Origin[mut=True], o_col: Origin
](
    enc_flat: UnsafePointer[Scalar[DType.int64], o_enc],
    base: Int,
    col: Pointer[Column[HeapRegion], o_col],
    num_rows: Int,
) raises:
    """Write `num_rows` Int64 ranks read from `col` (INT32 / INT64), honoring
    the column's logical `_offset`, into enc_flat[base .. base+num_rows)."""
    var off = col[]._offset
    if col[].arrow_type == ArrowType.INT64:
        var p_view = col[]._data.view_ro()
        var p = p_view._unsafe_ptr().bitcast[Scalar[DType.int64]]()
        for row in range(num_rows):
            (enc_flat + base + row)[] = Int64((p + off + row)[])
    else:
        var p_view = col[]._data.view_ro()
        var p = p_view._unsafe_ptr().bitcast[Scalar[DType.int32]]()
        for row in range(num_rows):
            (enc_flat + base + row)[] = Int64(Int((p + off + row)[]))


def _encode_string_key[
    o_enc: Origin[mut=True], o_col: Origin
](
    enc_flat: UnsafePointer[Scalar[DType.int64], o_enc],
    base: Int,
    col: Pointer[Column[HeapRegion], o_col],
    num_rows: Int,
) raises:
    """Dict-rank encode a STRING column: each row -> rank of its value in the
    lexicographic order of the column's distinct values, into enc_flat."""
    var off = col[]._offset
    var offs_view = col[]._offsets.value().view_ro()
    var offs_ptr = offs_view._unsafe_ptr().bitcast[Scalar[DType.int32]]()
    var data_view = col[]._data.view_ro()
    var data_ptr = data_view._unsafe_ptr().bitcast[Scalar[DType.uint8]]()

    # Hash-keyed dict of distinct values (verify-on-hit), mirroring the
    # COUNT(DISTINCT) agg's STRING-encode shape.
    var hash_dict = Dict[Int64, Int64]()
    var collision_dict = Dict[String, Int64]()
    var distinct = List[String]()
    var rev_starts = List[Int]()
    var rev_lens = List[Int]()
    var prov = List[Int](capacity=num_rows)

    for row in range(num_rows):
        var r = off + row
        var start = Int((offs_ptr + r)[])
        var end = Int((offs_ptr + r + 1)[])
        var slen = end - start
        var h = Int64(-3750763034362895579)  # FNV-1a 64-bit offset basis
        for b in range(slen):
            h = (h ^ Int64((data_ptr + start + b)[])) * Int64(1099511628211)
        h = h ^ (Int64(slen) * Int64(1099511628211))
        if h in hash_dict:
            var cand = Int(hash_dict[h])
            var ok = (rev_lens[cand] == slen)
            if ok and slen > 0:
                var cs = rev_starts[cand]
                var i = 0
                while i < slen:
                    if (data_ptr + start + i)[] != (data_ptr + cs + i)[]:
                        ok = False
                        break
                    i += 1
                keyeq_record(KEYEQ_SORTLEX_VERIFY, slen, i, ok)
            if ok:
                prov.append(cand)
                continue
            # Hash collision (rare): String-keyed fallback.
            var tmp = alloc[UInt8](slen + 1)
            if slen > 0:
                memcpy(dest=tmp, src=data_ptr + start, count=slen)
            (tmp + slen).init_pointee_copy(UInt8(0))
            var s = String(unsafe_from_utf8_ptr=tmp)
            tmp.free()
            if s in collision_dict:
                prov.append(Int(collision_dict[s]))
            else:
                var nid = len(distinct)
                collision_dict[s] = Int64(nid)
                distinct.append(s)
                rev_starts.append(start)
                rev_lens.append(slen)
                prov.append(nid)
        else:
            var nid = len(distinct)
            hash_dict[h] = Int64(nid)
            if slen == 0:
                distinct.append(String(""))
            else:
                var tmp = alloc[UInt8](slen + 1)
                memcpy(dest=tmp, src=data_ptr + start, count=slen)
                (tmp + slen).init_pointee_copy(UInt8(0))
                distinct.append(String(unsafe_from_utf8_ptr=tmp))
                tmp.free()
            rev_starts.append(start)
            rev_lens.append(slen)
            prov.append(nid)

    var perm = _sorted_perm_from_distinct(distinct)
    for row in range(num_rows):
        (enc_flat + base + row)[] = Int64(perm[prov[row]])


def _encode_dictionary_key[
    o_enc: Origin[mut=True], o_col: Origin
](
    enc_flat: UnsafePointer[Scalar[DType.int64], o_enc],
    base: Int,
    col: Pointer[Column[HeapRegion], o_col],
    num_rows: Int,
) raises:
    """Dict-rank encode a DICTIONARY column: decode the dictionary to strings,
    sort, then map each row's int32 dict index to its sorted rank."""
    # STRING-dict only — decodes the dictionary to strings via
    # `_offsets`/`_dict_data`. A NUMERIC dict has `_offsets == None` → DEFINED
    # raise, not a None-unwrap crash.
    if col[].is_numeric_dict():
        raise Error(
            "sort_batch_lex: NUMERIC dictionary sort key is not supported by"
            " the string-dict lex-encode path"
        )
    var d_size = col[]._dict_size
    var distinct = List[String]()
    var offs_src_view = col[]._offsets.value().view_ro()
    var offs_src = offs_src_view._unsafe_ptr().bitcast[Scalar[DType.int32]]()
    var data_src_view = col[]._dict_data.value().view_ro()
    var data_src = data_src_view._unsafe_ptr().bitcast[Scalar[DType.uint8]]()
    for d in range(d_size):
        var s = Int((offs_src + d)[])
        var e = Int((offs_src + d + 1)[])
        var slen = e - s
        if slen == 0:
            distinct.append(String(""))
        else:
            var tmp = alloc[UInt8](slen + 1)
            memcpy(dest=tmp, src=data_src + s, count=slen)
            (tmp + slen).init_pointee_copy(UInt8(0))
            distinct.append(String(unsafe_from_utf8_ptr=tmp))
            tmp.free()
    var perm = _sorted_perm_from_distinct(distinct)
    var off = col[]._offset
    var idx_src_view = col[]._data.view_ro()
    var idx_src = idx_src_view._unsafe_ptr().bitcast[Scalar[DType.int32]]()
    for row in range(num_rows):
        var di = Int((idx_src + off + row)[])
        if di < 0 or di >= len(perm):
            (enc_flat + base + row)[] = Int64(0)
        else:
            (enc_flat + base + row)[] = Int64(perm[di])


# -----------------------------------------------------------------------------
# Multi-key index merge sort over the (flattened) rank rows
# -----------------------------------------------------------------------------


@always_inline
def _row_lt[
    o_enc: Origin, o_desc: Origin
](
    enc_flat: UnsafePointer[Scalar[DType.int64], o_enc],
    num_rows: Int,
    desc_ptr: UnsafePointer[Scalar[DType.bool], o_desc],
    num_keys: Int,
    a: Int,
    b: Int,
) -> Bool:
    """Return True iff row `a` sorts strictly before row `b` lexicographically
    over the rank rows, applying the per-key descending flag."""
    for k in range(num_keys):
        var kb = k * num_rows
        var va = (enc_flat + kb + a)[]
        var vb = (enc_flat + kb + b)[]
        if va != vb:
            if (desc_ptr + k)[]:
                return va > vb
            return va < vb
    return False


def _insertion_sort_idx[
    o_idx: Origin[mut=True], o_enc: Origin, o_desc: Origin
](
    idx_ptr: UnsafePointer[Scalar[DType.int32], o_idx],
    enc_flat: UnsafePointer[Scalar[DType.int64], o_enc],
    num_rows: Int,
    desc_ptr: UnsafePointer[Scalar[DType.bool], o_desc],
    num_keys: Int,
    lo: Int,
    hi: Int,
):
    for i in range(lo + 1, hi):
        var key_idx = (idx_ptr + i)[]
        var j = i
        while j > lo and _row_lt(
            enc_flat, num_rows, desc_ptr, num_keys, Int(key_idx), Int((idx_ptr + j - 1)[])
        ):
            (idx_ptr + j)[] = (idx_ptr + j - 1)[]
            j -= 1
        (idx_ptr + j)[] = key_idx


def _merge_idx[
    o_idx: Origin[mut=True], o_tmp: Origin[mut=True], o_enc: Origin, o_desc: Origin
](
    idx_ptr: UnsafePointer[Scalar[DType.int32], o_idx],
    tmp: UnsafePointer[Scalar[DType.int32], o_tmp],
    enc_flat: UnsafePointer[Scalar[DType.int64], o_enc],
    num_rows: Int,
    desc_ptr: UnsafePointer[Scalar[DType.bool], o_desc],
    num_keys: Int,
    lo: Int,
    mid: Int,
    hi: Int,
):
    var rl = hi - lo
    memcpy(dest=tmp + lo, src=idx_ptr + lo, count=rl)
    var left = lo
    var right = mid
    var dest = lo
    while left < mid and right < hi:
        var li = Int((tmp + left)[])
        var ri = Int((tmp + right)[])
        # Stable: take left when keys are equal — left wins iff NOT (right < left).
        if not _row_lt(enc_flat, num_rows, desc_ptr, num_keys, ri, li):
            (idx_ptr + dest)[] = (tmp + left)[]
            left += 1
        else:
            (idx_ptr + dest)[] = (tmp + right)[]
            right += 1
        dest += 1
    var lrem = mid - left
    if lrem > 0:
        memcpy(dest=idx_ptr + dest, src=tmp + left, count=lrem)
    var rrem = hi - right
    if rrem > 0:
        memcpy(dest=idx_ptr + dest + lrem, src=tmp + right, count=rrem)


def _merge_sort_idx[
    o_idx: Origin[mut=True], o_tmp: Origin[mut=True], o_enc: Origin, o_desc: Origin
](
    idx_ptr: UnsafePointer[Scalar[DType.int32], o_idx],
    tmp: UnsafePointer[Scalar[DType.int32], o_tmp],
    enc_flat: UnsafePointer[Scalar[DType.int64], o_enc],
    num_rows: Int,
    desc_ptr: UnsafePointer[Scalar[DType.bool], o_desc],
    num_keys: Int,
    lo: Int,
    hi: Int,
):
    var n = hi - lo
    if n <= 1:
        return
    if n <= _INSERTION_SORT_THRESHOLD:
        _insertion_sort_idx(idx_ptr, enc_flat, num_rows, desc_ptr, num_keys, lo, hi)
        return
    var mid = lo + n // 2
    _merge_sort_idx(idx_ptr, tmp, enc_flat, num_rows, desc_ptr, num_keys, lo, mid)
    _merge_sort_idx(idx_ptr, tmp, enc_flat, num_rows, desc_ptr, num_keys, mid, hi)
    _merge_idx(idx_ptr, tmp, enc_flat, num_rows, desc_ptr, num_keys, lo, mid, hi)


# -----------------------------------------------------------------------------
# Public entry
# -----------------------------------------------------------------------------


def sort_batch_lex(
    var batch: RecordBatch,
    key_names: List[String],
    descending: List[Bool],
) raises -> RecordBatch:
    """Single-pass lexicographic multi-key sort. Pre-condition: every key
    column type is `lex_sort_supported_key(...)` True. Caller is responsible
    for the type check + fallback to `sort_batch_by_keys`."""
    var num_rows = batch.num_rows()
    var num_keys = len(key_names)
    if num_keys == 0 or num_rows <= 1:
        return batch^

    # Contiguous row-major rank buffer: enc_flat[k * num_rows + row].
    var enc_list = List[Int64](capacity=num_keys * num_rows)
    for _ in range(num_keys * num_rows):
        enc_list.append(Int64(0))
    var enc_flat = enc_list.unsafe_ptr()

    for k in range(num_keys):
        var ki = batch.schema.column_index(key_names[k])
        ref col = batch.column_at(ki)
        var at = col.arrow_type
        var base = k * num_rows
        if at == ArrowType.INT64 or at == ArrowType.INT32:
            _encode_int_key(enc_flat, base, Pointer(to=col), num_rows)
        elif at == ArrowType.STRING:
            _encode_string_key(enc_flat, base, Pointer(to=col), num_rows)
        elif at == ArrowType.DICTIONARY:
            _encode_dictionary_key(enc_flat, base, Pointer(to=col), num_rows)
        else:
            raise Error("sort_batch_lex: unsupported key type " + String(at))

    # ------------------------------------------------------------------ #
    # Fast path: when every key's encoded ranks span a small range, bit-pack
    # all K keys into ONE Int64 composite (primary key in the high bits) and
    # radix-sort it in O(N). Descending keys are stored as the complement of
    # their field value so a single ascending sort yields the right order.
    # For a 4-key TPC-H Q16-shaped sort that turns a ~250K-comparison merge
    # sort into a fixed 8-pass radix sweep.
    # ------------------------------------------------------------------ #
    var key_min = List[Int64](capacity=num_keys)
    var key_max = List[Int64](capacity=num_keys)
    for k in range(num_keys):
        var base = k * num_rows
        var lo64 = (enc_flat + base)[]
        var hi64 = lo64
        for row in range(1, num_rows):
            var v = (enc_flat + base + row)[]
            if v < lo64:
                lo64 = v
            if v > hi64:
                hi64 = v
        key_min.append(lo64)
        key_max.append(hi64)

    # Compute per-key bit widths (range = max - min, need ceil(log2(range+1))).
    var key_bits = List[Int](capacity=num_keys)
    var total_bits = 0
    var packable = True
    for k in range(num_keys):
        var span = UInt64(key_max[k] - key_min[k])  # >= 0
        var bits = 0
        var t = span
        while t > 0:
            bits += 1
            t >>= 1
        if bits == 0:
            bits = 1
        key_bits.append(bits)
        total_bits += bits
    if total_bits > 62:
        packable = False

    if packable:
        # Bit offsets: key 0 (primary) in the most-significant bits.
        var key_shift = List[Int](capacity=num_keys)
        var acc = total_bits
        for k in range(num_keys):
            acc -= key_bits[k]
            key_shift.append(acc)
        var packed = PrimitiveArray[DType.int64].allocate(num_rows)
        var packed_view = packed.view_mut()
        var packed_ptr = packed_view._unsafe_ptr().bitcast[Scalar[DType.int64]]()
        for row in range(num_rows):
            var composite = UInt64(0)
            for k in range(num_keys):
                var v = (enc_flat + k * num_rows + row)[]
                var field = UInt64(v - key_min[k])  # in [0, span]
                if descending[k]:
                    var fmask = (UInt64(1) << UInt64(key_bits[k])) - UInt64(1)
                    field = fmask - field
                composite |= field << UInt64(key_shift[k])
            (packed_ptr + row)[] = Int64(composite)
        var sort_idx = radix_sort_int64(packed)
        _ = packed^
        _ = enc_list^
        var result = gather_batch_by_sort_indices(batch, sort_idx)
        _ = batch  # keepalive (col pointers above borrow from it)
        return result^

    # ------------------------------------------------------------------ #
    # General path: stable multi-key merge sort over the rank rows.
    # ------------------------------------------------------------------ #
    var desc_list = List[Scalar[DType.bool]](capacity=num_keys)
    for k in range(num_keys):
        desc_list.append(Scalar[DType.bool](descending[k]))
    var desc_ptr = desc_list.unsafe_ptr()

    # Iota index array.
    var indices = PrimitiveArray[DType.int32].allocate(num_rows)
    var idx_view = indices.view_mut()
    var idx_ptr = idx_view._unsafe_ptr().bitcast[Scalar[DType.int32]]()
    for i in range(num_rows):
        (idx_ptr + i)[] = Scalar[DType.int32](i)

    var tmp_list = List[Scalar[DType.int32]](capacity=num_rows)
    for _ in range(num_rows):
        tmp_list.append(Scalar[DType.int32](0))
    var tmp_ptr = tmp_list.unsafe_ptr()

    _merge_sort_idx(idx_ptr, tmp_ptr, enc_flat, num_rows, desc_ptr, num_keys, 0, num_rows)

    _ = tmp_list^
    _ = desc_list^
    _ = enc_list^

    var result = gather_batch_by_sort_indices(batch, indices)
    _ = batch  # keepalive (col pointers above borrow from it)
    return result^
