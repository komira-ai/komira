# =============================================================================
# join_multi_key_outer -- the composite-key RIGHT and FULL outer probes,
# free functions over a `MultiKeyHashJoinBuilder` (siblings of the single-key
# `HashJoinBuilder.probe_right` / `probe_full`).
# =============================================================================
#
#   * RIGHT: every BUILD row appears at least once. A matched build row emits
#     `(build_idx, probe_idx)` per match; an unmatched one `(build_idx, -1)`.
#     An unmatched probe row is dropped. A probe row with a NULL key matches
#     nothing; a build row with a NULL key is linked from no chain, so it stays
#     unmatched and the sweep emits it.
#   * FULL: the LEFT probe (every probe row, `(-1, probe_idx)` when unmatched)
#     plus the same unmatched-build sweep.
#
# The sweep covers `builder.num_rows()`, the row-indexed entry space, and each
# probe checks at entry that it equals the build key column's length, so a
# build that stopped giving every row an entry raises here instead of
# silently dropping preserved rows. Output convention: `build_matches` holds
# the build row (or -1), `probe_matches` the probe row (or -1).
# =============================================================================

from std.memory import UnsafePointer

from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.string_array import StringArray
from komira_arrow.dictionary_array import StringDictionaryArray

from .join_multi_key import (
    MK_ARM_DICT,
    MK_ARM_INT,
    MK_ARM_MIXED,
    MK_ARM_STRING,
    MultiKeyColumns,
    _CHAIN_END,
    _NAN_SENTINEL_BITS,
    _composite_hash_int64,
    _string_bytes_equal,
    _null_ptr,
    mk_uniform_arm,
)
from .join_multi_key_builder import MultiKeyHashJoinBuilder


def multi_key_probe_right_into(
    ref builder: MultiKeyHashJoinBuilder,
    probe_keys: MultiKeyColumns,
    mut build_matches: List[Int],
    mut probe_matches: List[Int],
) raises:
    """Right outer join probe (composite key): every BUILD row appears at least
    once.

    Args:
        builder: The pre-built composite-key index (build keys + hash table +
            chain links + bloom). Read by `ref` (the SAME shape SEMI / ANTI use).
        probe_keys: N probe-side key columns (must match the build key count).
        build_matches: Appended the BUILD-side row idx per emitted row (or -1 for
            an unmatched probe — never -1 here for RIGHT).
        probe_matches: Appended the PROBE-side row idx per emitted row (-1 for an
            unmatched build row).
    """
    var n_keys = builder._num_keys
    if probe_keys.num_keys != n_keys:
        raise Error(
            "multi_key_probe_right_into: probe key count "
            + String(probe_keys.num_keys)
            + " != build key count "
            + String(n_keys)
        )
    var n = probe_keys.int_keys.value()[0].length
    var mask = UInt64(builder._capacity - 1)

    var num_build = builder._build_keys[0].length
    if builder.num_rows() != num_build:
        raise Error(
            "multi_key_probe_right_into: build entry space is not row-indexed"
            " (entry space="
            + String(builder.num_rows())
            + " != build rows="
            + String(num_build)
            + ") — the unmatched-build sweep would silently drop"
            " preserved-side rows"
        )

    var matched = List[Bool]()
    for _ in range(num_build):
        matched.append(False)

    # SAFETY: as in `MultiKeyHashJoinBuilder.probe_inner_into`: each pointer
    # carries the origin of `probe_keys` or of the builder's fields, both
    # borrowed for the whole call; none leaves this function.
    comptime po = origin_of(probe_keys.int_keys.value())
    comptime bo = origin_of(builder._build_keys)
    comptime pso = origin_of(probe_keys.string_keys.value())
    comptime bso = origin_of(builder._build_string_keys)
    comptime pdo = origin_of(probe_keys.dict_keys.value())
    comptime bdo = origin_of(builder._build_dict_keys)
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
        ref bref = builder._build_keys[k]
        build_ptrs.append(
            bref.view_ro()
                ._unsafe_ptr()
                .bitcast[Scalar[DType.int64]]()
                .unsafe_mut_cast[bo.mut]()
                .unsafe_origin_cast[bo]()
        )
        _ = bref
        ref pstr_slot = probe_keys.string_keys.value()[k]
        ref bstr_slot = builder._build_string_keys[k]
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
        ref bdict_slot = builder._build_dict_keys[k]
        var same_dict = False
        if pdict_slot.__bool__() and bdict_slot.__bool__():
            if probe_keys.dict_fingerprints.value()[k] == builder._build_dict_fingerprints[k]:
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
    var ht_ptr = builder._hash_table.unsafe_ptr()
    var nc_ptr = builder._next_chain.unsafe_ptr()

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
        var slot = Int(h & mask)
        var chain_idx = (ht_ptr + slot)[]
        while chain_idx != _CHAIN_END:
            var brow = chain_idx
            var is_match = True
            if _arm_u == MK_ARM_INT:
                for k in range(n_keys):
                    if Int64((build_ptrs[k] + brow)[]) != probe_buf[k]:
                        is_match = False
                        break
            elif _arm_u == MK_ARM_STRING:
                for k in range(n_keys):
                    if not _string_bytes_equal(
                        p_str_offs[k], p_str_data[k], probe_idx,
                        b_str_offs[k], b_str_data[k], brow,
                    ):
                        is_match = False
                        break
            elif _arm_u == MK_ARM_DICT:
                for k in range(n_keys):
                    if (p_dict_idx[k] + probe_idx)[] != (b_dict_idx[k] + brow)[]:
                        is_match = False
                        break
            else:
                for k in range(n_keys):
                    if is_same_dict[k]:
                        if (p_dict_idx[k] + probe_idx)[] != (b_dict_idx[k] + brow)[]:
                            is_match = False
                            break
                    elif is_string[k]:
                        if not _string_bytes_equal(
                            p_str_offs[k], p_str_data[k], probe_idx,
                            b_str_offs[k], b_str_data[k], brow,
                        ):
                            is_match = False
                            break
                    else:
                        if Int64((build_ptrs[k] + brow)[]) != probe_buf[k]:
                            is_match = False
                            break
            if is_match:
                build_matches.append(brow)
                probe_matches.append(probe_idx)
                matched[brow] = True
            chain_idx = (nc_ptr + chain_idx)[]

    for i in range(num_build):
        if not matched[i]:
            build_matches.append(i)
            probe_matches.append(-1)

    _ = builder._hash_table
    _ = builder._next_chain
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
    _ = matched


def multi_key_probe_full_into(
    ref builder: MultiKeyHashJoinBuilder,
    probe_keys: MultiKeyColumns,
    mut build_matches: List[Int],
    mut probe_matches: List[Int],
) raises:
    """Full outer join probe (composite key): every row from BOTH sides appears.

    Args:
        builder: The pre-built composite-key index (read by `ref`).
        probe_keys: N probe-side key columns (must match the build key count).
        build_matches: Appended the BUILD-side row idx per emitted row (-1 for an
            unmatched probe row).
        probe_matches: Appended the PROBE-side row idx per emitted row (-1 for an
            unmatched build row).
    """
    var n_keys = builder._num_keys
    if probe_keys.num_keys != n_keys:
        raise Error(
            "multi_key_probe_full_into: probe key count "
            + String(probe_keys.num_keys)
            + " != build key count "
            + String(n_keys)
        )
    var n = probe_keys.int_keys.value()[0].length
    var mask = UInt64(builder._capacity - 1)

    var num_build = builder._build_keys[0].length
    if builder.num_rows() != num_build:
        raise Error(
            "multi_key_probe_full_into: build entry space is not row-indexed"
            " (entry space="
            + String(builder.num_rows())
            + " != build rows="
            + String(num_build)
            + ") — the unmatched-build sweep would silently drop"
            " preserved-side rows"
        )

    var matched = List[Bool]()
    for _ in range(num_build):
        matched.append(False)

    # SAFETY: as in `multi_key_probe_right_into`.
    comptime po = origin_of(probe_keys.int_keys.value())
    comptime bo = origin_of(builder._build_keys)
    comptime pso = origin_of(probe_keys.string_keys.value())
    comptime bso = origin_of(builder._build_string_keys)
    comptime pdo = origin_of(probe_keys.dict_keys.value())
    comptime bdo = origin_of(builder._build_dict_keys)
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
        ref bref = builder._build_keys[k]
        build_ptrs.append(
            bref.view_ro()
                ._unsafe_ptr()
                .bitcast[Scalar[DType.int64]]()
                .unsafe_mut_cast[bo.mut]()
                .unsafe_origin_cast[bo]()
        )
        _ = bref
        ref pstr_slot = probe_keys.string_keys.value()[k]
        ref bstr_slot = builder._build_string_keys[k]
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
        ref bdict_slot = builder._build_dict_keys[k]
        var same_dict = False
        if pdict_slot.__bool__() and bdict_slot.__bool__():
            if probe_keys.dict_fingerprints.value()[k] == builder._build_dict_fingerprints[k]:
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
    var ht_ptr = builder._hash_table.unsafe_ptr()
    var nc_ptr = builder._next_chain.unsafe_ptr()

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
            var is_match = True
            if _arm_u == MK_ARM_INT:
                for k in range(n_keys):
                    if Int64((build_ptrs[k] + brow)[]) != probe_buf[k]:
                        is_match = False
                        break
            elif _arm_u == MK_ARM_STRING:
                for k in range(n_keys):
                    if not _string_bytes_equal(
                        p_str_offs[k], p_str_data[k], probe_idx,
                        b_str_offs[k], b_str_data[k], brow,
                    ):
                        is_match = False
                        break
            elif _arm_u == MK_ARM_DICT:
                for k in range(n_keys):
                    if (p_dict_idx[k] + probe_idx)[] != (b_dict_idx[k] + brow)[]:
                        is_match = False
                        break
            else:
                for k in range(n_keys):
                    if is_same_dict[k]:
                        if (p_dict_idx[k] + probe_idx)[] != (b_dict_idx[k] + brow)[]:
                            is_match = False
                            break
                    elif is_string[k]:
                        if not _string_bytes_equal(
                            p_str_offs[k], p_str_data[k], probe_idx,
                            b_str_offs[k], b_str_data[k], brow,
                        ):
                            is_match = False
                            break
                    else:
                        if Int64((build_ptrs[k] + brow)[]) != probe_buf[k]:
                            is_match = False
                            break
            if is_match:
                build_matches.append(brow)
                probe_matches.append(probe_idx)
                matched[brow] = True
                found = True
            chain_idx = (nc_ptr + chain_idx)[]
        if not found:
            build_matches.append(-1)
            probe_matches.append(probe_idx)

    for i in range(num_build):
        if not matched[i]:
            build_matches.append(i)
            probe_matches.append(-1)

    _ = builder._hash_table
    _ = builder._next_chain
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
    _ = matched
